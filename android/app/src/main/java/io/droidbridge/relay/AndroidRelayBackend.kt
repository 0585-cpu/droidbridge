package io.droidbridge.relay

import io.droidbridge.network.AndroidDnsTransport
import io.droidbridge.network.AndroidNetworkHandle
import io.droidbridge.network.CellularDnsForwarder
import io.droidbridge.network.CellularNetworkController
import io.droidbridge.network.CellularState
import io.droidbridge.protocol.OpenDestination
import java.net.Socket

/** Wires RelayServer to the live cellular controller and DNS forwarder. */
class AndroidRelayBackend(private val controller: CellularNetworkController) : RelayBackend {
    override suspend fun connect(destination: OpenDestination): Socket = controller.connectTcp(destination)

    override suspend fun resolveDns(queryPacket: ByteArray): ByteArray {
        val handle = controller.currentNetwork() as? AndroidNetworkHandle
            ?: throw io.droidbridge.network.CellularUnavailableException()
        val transport = AndroidDnsTransport(handle.network) { controller.currentDnsServers() }
        return CellularDnsForwarder(transport).query(queryPacket)
    }

    override fun carrierName(): String? = (controller.state.value as? CellularState.Available)?.carrierName
    override fun cellularReady(): Boolean = controller.state.value is CellularState.Available
}
