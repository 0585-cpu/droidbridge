package io.droidbridge.network

import io.droidbridge.protocol.OpenDestination
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test
import java.net.*

class CellularExtensionsTest {
    private class Net(val id: Int) : NetworkHandle
    private class Facade : ConnectivityFacade {
        lateinit var callback: CellularCallback
        var created: DatagramSocket? = null
        var duringCreate: (() -> Unit)? = null
        var applied=false
        var failOptions=false
        override fun requestCellular(callback: CellularCallback) { this.callback=callback }
        override fun unregister(callback: CellularCallback) {}
        override fun resolve(network: NetworkHandle,domain: String)=listOf(InetAddress.getByName("8.8.8.8"))
        override fun createSocket(network: NetworkHandle)=Socket()
        override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
        override fun createDatagramSocket(network: NetworkHandle): DatagramSocket = DatagramSocket(null).also { created=it; duringCreate?.invoke() }
        override fun applyPolicy(socket: DatagramSocket,address: InetAddress,policy: SocketEgressPolicy) { applied=true; if(failOptions) throw SocketPolicyException() }
    }
    @Test fun `UDP binding and options precede connect and stop closes socket`() = runBlocking {
        val facade=Facade(); val controller=CellularNetworkController(facade); controller.start(); facade.callback.onAvailable(Net(1),null)
        val socket=controller.connectUdp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443),SocketEgressPolicy(ipv4Ttl=65))
        assertTrue(facade.applied); assertTrue(socket.isConnected)
        val generation=controller.currentGeneration(); controller.stop()
        assertTrue(socket.isClosed); assertTrue(controller.currentGeneration() > generation)
    }
    @Test fun `network replacement closes old UDP and rejects late old open`() = runBlocking {
        val facade=Facade(); val controller=CellularNetworkController(facade); controller.start(); facade.callback.onAvailable(Net(1),null)
        val old=controller.connectUdp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443))
        facade.callback.onAvailable(Net(2),null)
        assertTrue(old.isClosed)
        facade.duringCreate={ facade.callback.onAvailable(Net(3),null) }
        try { controller.connectUdp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443)); fail("old generation accepted") } catch(_: CellularUnavailableException) {}
        assertTrue(facade.created!!.isClosed)
    }
    @Test fun `failed explicit options close UDP and private address opens nothing`() = runBlocking {
        val facade=Facade(); val controller=CellularNetworkController(facade); controller.start(); facade.callback.onAvailable(Net(1),null)
        facade.failOptions=true
        try { controller.connectUdp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443),SocketEgressPolicy(ipv4Ttl=65)); fail("options ignored") } catch(_: SocketPolicyException) {}
        assertTrue(facade.created!!.isClosed)
        facade.created=null
        try { controller.connectUdp(OpenDestination.Ipv4(byteArrayOf(127,0,0,1),443)); fail("private destination accepted") } catch(_: io.droidbridge.policy.DestinationDeniedException) {}
        assertNull(facade.created)
    }
}
