package io.droidbridge.network

import io.droidbridge.protocol.OpenDestination
import java.net.InetAddress
import java.net.Socket
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertSame
import kotlin.test.assertTrue

private class FakeNetwork(val name: String) : NetworkHandle

private class FakeSocket(val network: FakeNetwork) : Socket() {
    var connectedAddress: InetAddress? = null
    override fun connect(endpoint: java.net.SocketAddress?, timeout: Int) {
        connectedAddress = (endpoint as java.net.InetSocketAddress).address
    }
    override fun isConnected(): Boolean = connectedAddress != null
}

private class FakeFacade : ConnectivityFacade {
    var callback: CellularCallback? = null
    val defaultSocketFactoryCalls = intArrayOf(0)
    var resolveResult: List<InetAddress> = listOf(InetAddress.getByName("93.184.216.34"))
    var currentNetwork: FakeNetwork? = null

    override fun requestCellular(callback: CellularCallback) { this.callback = callback }
    override fun unregister(callback: CellularCallback) { this.callback = null }
    override fun resolve(network: NetworkHandle, domain: String): List<InetAddress> = resolveResult
    override fun dnsServers(network: NetworkHandle): List<InetAddress> = listOf(InetAddress.getByName("8.8.8.8"))
    override fun createSocket(network: NetworkHandle): Socket {
        kotlin.test.assertSame<Any?>(currentNetwork, network) // never the default/Wi-Fi factory
        return FakeSocket(network as FakeNetwork)
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class CellularNetworkControllerTest {
    private fun controller(facade: FakeFacade) = CellularNetworkController(facade)

    @Test
    fun `connect before onAvailable fails closed`() = runTest {
        val facade = FakeFacade()
        val controller = controller(facade)
        controller.start()
        assertFailsWith<CellularUnavailableException> {
            controller.connectTcp(OpenDestination.Domain("example.com", 443))
        }
        assertEquals(0, facade.defaultSocketFactoryCalls[0])
    }

    @Test
    fun `connect after onAvailable binds to cellular and rechecks policy`() = runTest {
        val facade = FakeFacade()
        val net = FakeNetwork("lte").also { facade.currentNetwork = it }
        val controller = controller(facade)
        controller.start()
        facade.callback!!.onAvailable(net, "TestCarrier")
        controller.state.first { it is CellularState.Available }

        val socket = controller.connectTcp(OpenDestination.Domain("example.com", 443)) as FakeSocket
        assertSame(net, socket.network)
        assertEquals("93.184.216.34", socket.connectedAddress!!.hostAddress)
        assertEquals("TestCarrier", (controller.state.value as CellularState.Available).carrierName)
    }

    @Test
    fun `connect after onLost fails closed and cancels flows`() = runTest {
        val facade = FakeFacade()
        val net = FakeNetwork("lte").also { facade.currentNetwork = it }
        val controller = controller(facade)
        controller.start()
        facade.callback!!.onAvailable(net, "C")
        controller.state.first { it is CellularState.Available }

        var cancelled = false
        controller.addLossListener { cancelled = true }
        facade.callback!!.onLost(net)
        controller.state.first { it is CellularState.Lost }
        assertTrue(cancelled)
        assertFailsWith<CellularUnavailableException> {
            controller.connectTcp(OpenDestination.Ipv4(byteArrayOf(93, 184.toByte(), 216.toByte(), 34), 443))
        }
    }

    @Test
    fun `network replaced mid-connect fails rather than using a stale generation`() = runTest {
        val facade = FakeFacade()
        val net1 = FakeNetwork("lte1").also { facade.currentNetwork = it }
        val gate = CompletableDeferred<Unit>()
        val slowFacade = object : ConnectivityFacade by facade {
            override fun resolve(network: NetworkHandle, domain: String): List<InetAddress> {
                // simulate a replacement landing while resolution is in flight
                val net2 = FakeNetwork("lte2")
                facade.currentNetwork = net2
                facade.callback!!.onAvailable(net2, "C2")
                gate.complete(Unit)
                return facade.resolveResult
            }
        }
        val controller = CellularNetworkController(slowFacade)
        controller.start()
        facade.callback!!.onAvailable(net1, "C1")
        controller.state.first { it is CellularState.Available && it.network === net1 }

        assertFailsWith<CellularUnavailableException> {
            controller.connectTcp(OpenDestination.Domain("example.com", 443))
        }
    }

    @Test
    fun `all-private DNS answers are denied without opening a socket`() = runTest {
        val facade = FakeFacade()
        val net = FakeNetwork("lte").also { facade.currentNetwork = it }
        facade.resolveResult = listOf(InetAddress.getByName("10.0.0.1"), InetAddress.getByName("192.168.1.1"))
        val controller = controller(facade)
        controller.start()
        facade.callback!!.onAvailable(net, "C")
        controller.state.first { it is CellularState.Available }
        assertFailsWith<io.droidbridge.policy.DestinationDeniedException> {
            controller.connectTcp(OpenDestination.Domain("rebind.test", 443))
        }
    }
}
