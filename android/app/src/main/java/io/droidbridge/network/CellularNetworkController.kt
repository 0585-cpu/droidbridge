package io.droidbridge.network

import io.droidbridge.policy.DestinationPolicy
import io.droidbridge.protocol.OpenDestination
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext

class CellularUnavailableException(message: String = "cellular unavailable") : Exception(message)

sealed interface CellularState {
    data object Unavailable : CellularState
    data object Requesting : CellularState
    data class Available(val network: NetworkHandle, val carrierName: String?) : CellularState
    data object Lost : CellularState
}

private const val CONNECT_TIMEOUT_MS = 10_000

/**
 * Owns the selected cellular Network and opens outbound sockets bound to it. Every connect snapshots a
 * (network, generation) pair; if the network is replaced or lost at any point the connect fails closed
 * rather than falling back to Wi-Fi or another interface.
 */
class CellularNetworkController(private val facade: ConnectivityFacade) : CellularCallback {
    private val _state = MutableStateFlow<CellularState>(CellularState.Unavailable)
    val state: StateFlow<CellularState> = _state

    private val lossListeners = CopyOnWriteArrayList<() -> Unit>()

    @Volatile private var network: NetworkHandle? = null
    @Volatile private var generation: Long = 0

    fun start() {
        _state.value = CellularState.Requesting
        facade.requestCellular(this)
    }

    fun stop() {
        facade.unregister(this)
        network = null
        _state.value = CellularState.Unavailable
    }

    fun addLossListener(listener: () -> Unit) { lossListeners += listener }

    fun currentNetwork(): NetworkHandle? = network
    fun currentDnsServers(): List<InetAddress> = network?.let { facade.dnsServers(it) } ?: emptyList()

    override fun onAvailable(network: NetworkHandle, carrierName: String?) {
        this.network = network
        generation++
        _state.value = CellularState.Available(network, carrierName)
    }

    override fun onLost(network: NetworkHandle) {
        if (this.network == network || this.network == null) {
            this.network = null
            generation++
            _state.value = CellularState.Lost
            lossListeners.forEach { it() }
        }
    }

    suspend fun connectTcp(destination: OpenDestination): Socket = withContext(Dispatchers.IO) {
        val snapshotNetwork = network ?: throw CellularUnavailableException()
        val snapshotGeneration = generation

        val candidates = when (destination) {
            is OpenDestination.Ipv4 -> listOf(InetAddress.getByAddress(destination.address))
            is OpenDestination.Domain -> {
                val resolved = facade.resolve(snapshotNetwork, destination.host)
                DestinationPolicy.filterResolved(destination.host, resolved)
            }
        }
        if (generation != snapshotGeneration || network !== snapshotNetwork) throw CellularUnavailableException("network changed during resolve")

        var lastError: Exception? = null
        for (address in candidates) {
            DestinationPolicy.requireAllowed(address) // re-check the exact connect target (DNS rebinding guard)
            val socket = facade.createSocket(snapshotNetwork)
            try {
                if (generation != snapshotGeneration || network !== snapshotNetwork) throw CellularUnavailableException("network changed before connect")
                socket.connect(InetSocketAddress(address, destination.port), CONNECT_TIMEOUT_MS)
                return@withContext socket
            } catch (e: CellularUnavailableException) {
                socket.close()
                throw e
            } catch (e: java.io.IOException) {
                socket.close()
                lastError = e
            }
        }
        throw lastError?.let { CellularUnavailableException("connect failed: ${it.message}") } ?: CellularUnavailableException()
    }
}
