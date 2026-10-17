package io.droidbridge.network

import io.droidbridge.relay.*
import io.droidbridge.protocol.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.net.*

class UdpAssociationCellularTest {
    private class Net : NetworkHandle
    private class Facade : ConnectivityFacade {
        lateinit var callback: CellularCallback
        var created: DatagramSocket?=null
        var duringCreate: (() -> Unit)?=null
        var failPolicy=false
        var associationSupported=true
        override fun supportsUdpAssociation(network: NetworkHandle)=associationSupported
        var policyFamily=0
        var appliedPolicy: SocketEgressPolicy?=null
        override fun requestCellular(callback: CellularCallback) { this.callback=callback }
        override fun unregister(callback: CellularCallback) {}
        override fun resolve(network: NetworkHandle,domain: String)=emptyList<InetAddress>()
        override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
        override fun createSocket(network: NetworkHandle)=Socket()
        override fun createDatagramSocket(network: NetworkHandle)=DatagramSocket(null as SocketAddress?).also { created=it; duringCreate?.invoke() }
        override fun applyPolicy(socket: DatagramSocket,address: InetAddress,policy: SocketEgressPolicy) {
            assertFalse(socket.isConnected)
            policyFamily=address.address.size; appliedPolicy=policy
            if(failPolicy) throw SocketPolicyException()
        }
    }
    @Test fun `association applies family policy before returning unconnected socket and generation retires it`() = runBlocking {
        val facade=Facade(); val controller=CellularNetworkController(facade).apply { start() }
        val net=Net(); facade.callback.onAvailable(net,null)
        val backend=AndroidRelayBackend(controller).apply { beginRun(TrafficProfile(socketPolicy=SocketEgressPolicy(ipv4Ttl=65))) }
        try {
            val socket=backend.openUdpAssociation(4)
            assertFalse(socket.isConnected); assertTrue(socket.isBound)
            assertEquals(4,facade.policyFamily); assertEquals(65,facade.appliedPolicy!!.ipv4Ttl)
            facade.callback.onChanged(net)
            assertTrue(socket.isClosed)
        } finally { controller.stop() }
    }
    @Test fun `late association creation and failed options close allocated sockets`() = runBlocking {
        val facade=Facade(); val controller=CellularNetworkController(facade).apply { start() }
        facade.callback.onAvailable(Net(),null)
        val backend=AndroidRelayBackend(controller)
        try {
            facade.duringCreate={ facade.callback.onAvailable(Net(),null) }
            try { backend.openUdpAssociation(4); fail("retired generation accepted") } catch(_: CellularUnavailableException) {}
            assertTrue(facade.created!!.isClosed)
            facade.duringCreate=null; facade.failPolicy=true
            try { backend.openUdpAssociation(4); fail("policy failure ignored") } catch(_: SocketPolicyException) {}
            assertTrue(facade.created!!.isClosed)
        } finally { controller.stop() }
    }
    @Test fun `unavailable IPv6 association allocates nothing`() = runBlocking {
        val facade=Facade(); val controller=CellularNetworkController(facade).apply { start() }
        facade.callback.onAvailable(Net(),null)
        try {
            try { AndroidRelayBackend(controller).openUdpAssociation(6); fail("unavailable IPv6 accepted") } catch(_: AddressFamilyUnavailableException) {}
            assertNull(facade.created)
        } finally { controller.stop() }
    }
    @Test fun `association capability requires available supporting backend`() {
        val facade=Facade(); val controller=CellularNetworkController(facade)
        val backend=AndroidRelayBackend(controller)
        assertEquals(0,backend.capabilities().flags and Capability.UDP_ASSOCIATION)
        controller.start(); facade.callback.onAvailable(Net(),null)
        try {
            facade.associationSupported=false
            assertEquals(0,backend.capabilities().flags and Capability.UDP_ASSOCIATION)
            facade.associationSupported=true
            assertEquals(Capability.UDP_ASSOCIATION,backend.capabilities().flags and Capability.UDP_ASSOCIATION)
            controller.stop()
            assertEquals(0,backend.capabilities().flags and Capability.UDP_ASSOCIATION)
        } finally { controller.stop() }
    }

}
