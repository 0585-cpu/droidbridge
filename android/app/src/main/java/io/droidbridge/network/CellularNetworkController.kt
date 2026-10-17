package io.droidbridge.network

import io.droidbridge.policy.DestinationDeniedException
import io.droidbridge.policy.DestinationPolicy
import io.droidbridge.protocol.OpenDestination
import java.io.Closeable
import java.net.*
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

class CellularUnavailableException(message: String = "cellular unavailable") : Exception(message)
class AddressFamilyUnavailableException : Exception("address family unavailable")

sealed interface CellularState {
    data object Unavailable : CellularState
    data object Requesting : CellularState
    data class Available(val network: NetworkHandle, val carrierName: String?) : CellularState
    data object Lost : CellularState
}

enum class CellularRetirementReason { AVAILABLE, REPLACED, LINK_PROPERTIES_CHANGED, LOST, STOP }
data class CellularRetirementEvent(val reason: CellularRetirementReason,val generation: Long,val trackedSocketCount: Int)

data class CellularSnapshot(val network: NetworkHandle,val generation: Long)

/** Owns every cellular socket from before connect through release. Replacement, loss and Stop retire
 * the entire generation, including sockets whose connect operation is still pending. */
class CellularNetworkController(
    private val facade: ConnectivityFacade,
    private val onRetirement: (CellularRetirementEvent) -> Unit = {},
) : CellularCallback {
    private val _state=MutableStateFlow<CellularState>(CellularState.Unavailable)
    val state: StateFlow<CellularState> = _state
    private val lossListeners=CopyOnWriteArrayList<() -> Unit>()
    private val sockets=mutableSetOf<Closeable>()
    private var network: NetworkHandle?=null
    private var generation=0L
    private var running=false

    @Synchronized fun start() { if(running) return; running=true; _state.value=CellularState.Requesting; facade.requestCellular(this) }
    @Synchronized fun stop() { running=false; facade.unregister(this); retire(CellularRetirementReason.STOP); network=null; _state.value=CellularState.Unavailable }
    fun addLossListener(listener: () -> Unit) { lossListeners+=listener }
    @Synchronized fun currentNetwork(): NetworkHandle?=network
    @Synchronized fun currentGeneration(): Long=generation
    fun currentDnsServers(): List<InetAddress> = currentNetwork()?.let { facade.dnsServers(it) } ?: emptyList()
    fun udpAssociationAvailable(): Boolean = currentNetwork()?.let { facade.supportsUdpAssociation(it) } ?: false
    fun ipv6Available(): Boolean = currentNetwork()?.let { facade.supportsIpv6(it) } ?: false
    fun nat64Prefix(): ByteArray?=currentNetwork()?.let { facade.nat64Prefix(it) }
    @Synchronized fun snapshot(): CellularSnapshot = CellularSnapshot(network ?: throw CellularUnavailableException(),generation)
    @Synchronized fun requireCurrent(snapshot: CellularSnapshot) { if(!running || network != snapshot.network || generation != snapshot.generation) throw CellularUnavailableException("network generation retired") }
    @Synchronized fun track(snapshot: CellularSnapshot,socket: Closeable) {
        try { requireCurrent(snapshot); sockets+=socket } catch(e: Exception) { socket.close(); throw e }
    }
    @Synchronized fun release(socket: Closeable) { sockets-=socket; facade.releaseSocket(socket) }
    @Synchronized override fun onAvailable(network: NetworkHandle,carrierName: String?) {
        if(!running) return
        if(this.network != network) { retire(if(this.network==null) CellularRetirementReason.AVAILABLE else CellularRetirementReason.REPLACED); this.network=network }
        _state.value=CellularState.Available(network,carrierName)
    }
    @Synchronized override fun onLost(network: NetworkHandle) {
        if(this.network == network) { retire(CellularRetirementReason.LOST); this.network=null; _state.value=CellularState.Lost }
    }
    @Synchronized override fun onChanged(network: NetworkHandle) { if(running && this.network == network) retire(CellularRetirementReason.LINK_PROPERTIES_CHANGED) }
    private fun retire(reason: CellularRetirementReason) {
        generation++
        // One bounded record before descriptor closure; no addresses, carrier or platform objects.
        try { onRetirement(CellularRetirementEvent(reason,generation,sockets.size)) } catch(_: Exception) { }
        sockets.toList().forEach { runCatching { it.close() }; facade.releaseSocket(it) }
        sockets.clear(); lossListeners.forEach { it() }
    }

    fun requireAllowed(address: InetAddress) {
        if(address.address.size==16) synchronized(this) {
            // The framework callback uses this monitor: NAT64 and availability belong to one
            // snapshot. IPv4 policy does not depend on network properties or need this lock.
            val result=DestinationPolicy.evaluateIpv6(address.address,nat64Prefix())
            if(!result.allowed) throw DestinationDeniedException(result)
            if(!ipv6Available()) throw AddressFamilyUnavailableException()
        } else DestinationPolicy.requireAllowed(address)
    }
    // Separate, bounded upstream workers: slow DNS/connect must never occupy HEALTH workers.
    private val pendingConnects = java.util.concurrent.Semaphore(32)
    private val connectDispatcher = Dispatchers.IO.limitedParallelism(32)

    suspend fun connectTcp(destination: OpenDestination, policy: SocketEgressPolicy = SocketEgressPolicy()): Socket =
        suspendCancellableCoroutine { continuation ->
            if (!pendingConnects.tryAcquire()) {
                continuation.resumeWith(Result.failure(SocketTimeoutException("pending connect limit reached")))
                return@suspendCancellableCoroutine
            }
            class OwnedSocket(val socket: Socket) {
                private val closed = java.util.concurrent.atomic.AtomicBoolean()
                fun close() { if (closed.compareAndSet(false, true)) { runCatching { socket.close() }; release(socket) } }
            }
            val owned = java.util.concurrent.atomic.AtomicReference<OwnedSocket?>()
            continuation.invokeOnCancellation { owned.get()?.close() }
            // The permit belongs to the blocking worker, not its caller. Even a broken platform
            // resolver that ignores cancellation cannot grow an unbounded worker/dispatch queue.
            connectDispatcher.dispatch(continuation.context, Runnable {
                try {
                    continuation.context.ensureActive()
                    val snapshot = snapshot()
                    val candidates = when(destination) {
                        is OpenDestination.Ipv4 -> listOf(InetAddress.getByAddress(destination.address))
                        is OpenDestination.Ipv6 -> listOf(Inet6Address.getByAddress(null,destination.address,-1))
                        is OpenDestination.Domain -> facade.resolve(snapshot.network,destination.host).filter { address ->
                            if(address.address.size==16) ipv6Available() && DestinationPolicy.evaluateIpv6(address.address,nat64Prefix()).allowed
                            else DestinationPolicy.evaluate(address).allowed
                        }.also { if(it.isEmpty()) throw DestinationDeniedException(io.droidbridge.policy.PolicyResult.DENY_RESERVED) }
                    }
                    val deadline = System.nanoTime() + 10_000_000_000L
                    var last: Exception? = null
                    for (address in candidates) {
                        continuation.context.ensureActive()
                        requireCurrent(snapshot)
                        requireAllowed(address)
                        val current = OwnedSocket(facade.createSocket(snapshot.network))
                        try {
                            track(snapshot,current.socket)
                            owned.set(current)
                            continuation.context.ensureActive()
                            facade.applyPolicy(current.socket,address,policy)
                            val remaining = (deadline-System.nanoTime())/1_000_000
                            if (remaining <= 0) throw SocketTimeoutException("connect deadline exceeded")
                            current.socket.connect(InetSocketAddress(address,destination.port),remaining.coerceAtMost(10_000).toInt().coerceAtLeast(1))
                            requireCurrent(snapshot)
                            continuation.context.ensureActive()
                            continuation.resume(current.socket) { _, _, _ -> current.close() }
                            return@Runnable
                        } catch (error: Exception) {
                            current.close()
                            continuation.context.ensureActive() // cancellation never falls through to another address
                            if(error is CellularUnavailableException || error is SocketPolicyException) throw error
                            last = error
                        }
                    }
                    throw last ?: CellularUnavailableException()
                } catch (error: Exception) {
                    owned.get()?.close()
                    continuation.resumeWith(Result.failure(error))
                } finally { pendingConnects.release() }
            })
        }
    suspend fun connectUdp(destination: OpenDestination,policy: SocketEgressPolicy=SocketEgressPolicy()): DatagramSocket {
        var opened: DatagramSocket?=null
        try {
            return withContext(Dispatchers.IO) {
                val snapshot=snapshot()
                val address=when(destination) {
                    is OpenDestination.Ipv4 -> InetAddress.getByAddress(destination.address)
                    is OpenDestination.Ipv6 -> Inet6Address.getByAddress(null,destination.address,-1)
                    is OpenDestination.Domain -> throw IllegalArgumentException("UDP requires literal address")
                }
                requireAllowed(address)
                val socket=facade.createDatagramSocket(snapshot.network); opened=socket
                track(snapshot,socket)
                facade.applyPolicy(socket,address,policy)
                requireCurrent(snapshot)
                socket.connect(InetSocketAddress(address,destination.port))
                requireCurrent(snapshot); ensureActive()
                socket
            }
        } catch(e: Exception) { opened?.let { it.close(); release(it) }; throw e }
    }
    /** Network binding and family policy are established before the first packet or receive. */
    suspend fun openUdpAssociation(family: Int,policy: SocketEgressPolicy=SocketEgressPolicy()): DatagramSocket {
        require(family==4 || family==6)
        var opened: DatagramSocket?=null
        try {
            return withContext(Dispatchers.IO) {
                val snapshot=snapshot()
                if(!facade.supportsUdpAssociation(snapshot.network)) throw UnsupportedOperationException("UDP association unavailable")
                if(family==6 && !facade.supportsIpv6(snapshot.network)) throw AddressFamilyUnavailableException()
                val address=if(family==4) InetAddress.getByAddress(ByteArray(4)) else Inet6Address.getByAddress(null,ByteArray(16),-1)
                val socket=facade.createDatagramSocket(snapshot.network); opened=socket
                track(snapshot,socket)
                facade.applyPolicy(socket,address,policy)
                requireCurrent(snapshot)
                if(!socket.isBound) socket.bind(InetSocketAddress(address,0))
                requireCurrent(snapshot); ensureActive()
                socket
            }
        } catch(e: Exception) { opened?.let { it.close(); release(it) }; throw e }
    }

}
