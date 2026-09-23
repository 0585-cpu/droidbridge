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

data class CellularSnapshot(val network: NetworkHandle,val generation: Long)

/** Owns every cellular socket from before connect through release. Replacement, loss and Stop retire
 * the entire generation, including sockets whose connect operation is still pending. */
class CellularNetworkController(private val facade: ConnectivityFacade) : CellularCallback {
    private val _state=MutableStateFlow<CellularState>(CellularState.Unavailable)
    val state: StateFlow<CellularState> = _state
    private val lossListeners=CopyOnWriteArrayList<() -> Unit>()
    private val sockets=mutableSetOf<Closeable>()
    private var network: NetworkHandle?=null
    private var generation=0L
    private var running=false

    @Synchronized fun start() { if(running) return; running=true; _state.value=CellularState.Requesting; facade.requestCellular(this) }
    @Synchronized fun stop() { running=false; facade.unregister(this); retire(); network=null; _state.value=CellularState.Unavailable }
    fun addLossListener(listener: () -> Unit) { lossListeners+=listener }
    @Synchronized fun currentNetwork(): NetworkHandle?=network
    @Synchronized fun currentGeneration(): Long=generation
    fun currentDnsServers(): List<InetAddress> = currentNetwork()?.let { facade.dnsServers(it) } ?: emptyList()
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
        if(this.network != network) { retire(); this.network=network }
        _state.value=CellularState.Available(network,carrierName)
    }
    @Synchronized override fun onLost(network: NetworkHandle) {
        if(this.network == network) { retire(); this.network=null; _state.value=CellularState.Lost }
    }
    @Synchronized override fun onChanged(network: NetworkHandle) { if(running && this.network == network) retire() }
    private fun retire() { generation++; sockets.toList().forEach { runCatching { it.close() }; facade.releaseSocket(it) }; sockets.clear(); lossListeners.forEach { it() } }

    fun requireAllowed(address: InetAddress) {
        if(address.address.size==16) {
            val result=DestinationPolicy.evaluateIpv6(address.address,nat64Prefix())
            if(!result.allowed) throw DestinationDeniedException(result)
            if(!ipv6Available()) throw AddressFamilyUnavailableException()
        } else DestinationPolicy.requireAllowed(address)
    }
    suspend fun connectTcp(destination: OpenDestination,policy: SocketEgressPolicy=SocketEgressPolicy()): Socket {
        var opened: Socket?=null
        try {
            return withContext(Dispatchers.IO) {
                val snapshot=snapshot()
                val candidates=when(destination) {
                    is OpenDestination.Ipv4 -> listOf(InetAddress.getByAddress(destination.address))
                    is OpenDestination.Ipv6 -> listOf(Inet6Address.getByAddress(null,destination.address,-1))
                    is OpenDestination.Domain -> facade.resolve(snapshot.network,destination.host).filter { address ->
                        if(address.address.size==16) ipv6Available() && DestinationPolicy.evaluateIpv6(address.address,nat64Prefix()).allowed
                        else DestinationPolicy.evaluate(address).allowed
                    }.also { if(it.isEmpty()) throw DestinationDeniedException(io.droidbridge.policy.PolicyResult.DENY_RESERVED) }
                }
                requireCurrent(snapshot)
                var last: Exception?=null
                for(address in candidates) {
                    requireAllowed(address)
                    val socket=facade.createSocket(snapshot.network); opened=socket
                    try {
                        track(snapshot,socket)
                        facade.applyPolicy(socket,address,policy)
                        requireCurrent(snapshot)
                        socket.connect(InetSocketAddress(address,destination.port),10_000)
                        requireCurrent(snapshot); ensureActive()
                        return@withContext socket
                    } catch(e: Exception) {
                        socket.close(); release(socket); opened=null
                        if(e is CellularUnavailableException || e is SocketPolicyException || e is CancellationException) throw e
                        last=e
                    }
                }
                throw last ?: CellularUnavailableException()
            }
        } catch(e: Exception) { opened?.let { it.close(); release(it) }; throw e }
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
}
