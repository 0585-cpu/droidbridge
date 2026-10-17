package io.droidbridge.network

import android.content.Context
import android.net.*
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.util.ReflectionHelpers
import org.robolectric.util.ReflectionHelpers.ClassParameter
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket
import java.net.SocketAddress

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],shadows=[AndroidCellularTransportTest.ManagerShadow::class])
class AndroidCellularTransportTest {
    @Implements(ConnectivityManager::class)
    class ManagerShadow {
        lateinit var callback: ConnectivityManager.NetworkCallback
        var properties: LinkProperties?=null
        var propertyReads=0
        var failRequest=false
        @Implementation fun requestNetwork(request: NetworkRequest,callback: ConnectivityManager.NetworkCallback) {
            this.callback=callback
            if(failRequest) throw SecurityException("request denied")
        }
        @Implementation fun unregisterNetworkCallback(callback: ConnectivityManager.NetworkCallback) {}
        @Implementation fun getLinkProperties(network: Network): LinkProperties? { propertyReads++; return properties }
    }
    // Hidden framework constructors are used only to create test fixtures; production uses public getters.
    private fun prefix(address: String,bits: Int): IpPrefix = ReflectionHelpers.callConstructor(IpPrefix::class.java,
        ClassParameter.from(InetAddress::class.java,InetAddress.getByName(address)),ClassParameter.from(Int::class.javaPrimitiveType!!,bits))
    private fun address(host: String,bits: Int): LinkAddress = ReflectionHelpers.callConstructor(LinkAddress::class.java,
        ClassParameter.from(InetAddress::class.java,InetAddress.getByName(host)),ClassParameter.from(Int::class.javaPrimitiveType!!,bits))
    private fun route(destination: String="0.0.0.0",bits: Int=0,gateway: String="192.0.2.1",type: Int=RouteInfo.RTN_UNICAST): RouteInfo =
        ReflectionHelpers.callConstructor(RouteInfo::class.java,ClassParameter.from(IpPrefix::class.java,prefix(destination,bits)),
            ClassParameter.from(InetAddress::class.java,InetAddress.getByName(gateway)),ClassParameter.from(String::class.java,"rmnet0"),ClassParameter.from(Int::class.javaPrimitiveType!!,type))
    private fun properties(reversed: Boolean=false)=LinkProperties().apply {
        interfaceName="rmnet0"
        val addresses=listOf(address("192.0.2.2",24),address("2001:db8::2",64))
        setLinkAddresses(if(reversed) addresses.reversed() else addresses)
        val paths=listOf(route(),route("2001:db8::",64,"2001:db8::1"))
        (if(reversed) paths.reversed() else paths).forEach(::addRoute)
        nat64Prefix=prefix("64:ff9b::",96)
    }
    private inner class Harness : AutoCloseable {
        val manager=ApplicationProvider.getApplicationContext<Context>().getSystemService(ConnectivityManager::class.java)
        val shadow=Shadow.extract<ManagerShadow>(manager)
        val events=mutableListOf<CellularRetirementEvent>()
        val transport=AndroidCellularTransport(manager,null)
        val controller=CellularNetworkController(transport,events::add)
        val network=ShadowNetwork.newInstance(42)
        val tcp=Socket()
        val udp=DatagramSocket(null as SocketAddress?)
        var losses=0
        init {
            controller.addLossListener { losses++ }
            controller.start(); shadow.callback.onAvailable(network)
            controller.track(controller.snapshot(),tcp); controller.track(controller.snapshot(),udp)
        }
        fun changed(properties: LinkProperties)=shadow.callback.onLinkPropertiesChanged(network,properties)
        override fun close() { controller.stop(); tcp.close(); udp.close() }
    }
    private fun ipv6Properties()=properties().apply {
        addRoute(route("::",0,"2001:db8::1"))
        setDnsServers(listOf(InetAddress.getByName("2001:4860:4860::8888")))
    }
    @Test fun `failed request fences late callbacks and leaves properties unavailable`() {
        val manager=ApplicationProvider.getApplicationContext<Context>().getSystemService(ConnectivityManager::class.java)
        val shadow=Shadow.extract<ManagerShadow>(manager)
        val transport=AndroidCellularTransport(manager,null)
        var callbacks=0
        val listener=object: CellularCallback {
            override fun onAvailable(network: NetworkHandle,carrierName: String?) { callbacks++ }
            override fun onLost(network: NetworkHandle) { callbacks++ }
        }
        shadow.failRequest=true
        assertThrows(SecurityException::class.java) { transport.requestCellular(listener) }
        val failed=shadow.callback
        val network=ShadowNetwork.newInstance(42)
        failed.onAvailable(network); failed.onLinkPropertiesChanged(network,ipv6Properties())
        assertEquals(0,callbacks)
        assertFalse(transport.supportsIpv6(AndroidNetworkHandle(network)))
        assertNull(transport.nat64Prefix(AndroidNetworkHandle(network)))
        assertTrue(transport.dnsServers(AndroidNetworkHandle(network)).isEmpty())
        shadow.failRequest=false
        transport.requestCellular(listener)
        shadow.callback.onAvailable(network); shadow.callback.onLinkPropertiesChanged(network,ipv6Properties())
        failed.onLost(network)
        assertEquals(1,callbacks)
        assertTrue(transport.supportsIpv6(AndroidNetworkHandle(network)))
        transport.unregister(listener)
    }
    @Test fun `properties fail closed until the selected network callback supplies them`() {
        Harness().use { h ->
            h.shadow.properties=ipv6Properties() // A framework getter can still describe an older path.
            assertFalse(h.controller.ipv6Available())
            assertNull(h.controller.nat64Prefix())
            assertTrue(h.controller.currentDnsServers().isEmpty())
            assertThrows(AddressFamilyUnavailableException::class.java) {
                h.controller.requireAllowed(InetAddress.getByName("2001:4860:4860::8888"))
            }
            assertEquals(0,h.shadow.propertyReads)
        }
    }
    @Test fun `packet policy uses immutable callback properties without framework reads`() {
        Harness().use { h ->
            val callbackProperties=ipv6Properties()
            h.changed(callbackProperties)
            callbackProperties.clear() // The caller retains a mutable framework object.
            repeat(256) {
                h.controller.requireAllowed(InetAddress.getByName("2001:4860:4860::8888"))
                assertArrayEquals(InetAddress.getByName("64:ff9b::").address,h.controller.nat64Prefix())
                assertEquals(listOf(InetAddress.getByName("2001:4860:4860::8888")),h.controller.currentDnsServers())
            }
            h.controller.nat64Prefix()!!.fill(0)
            assertArrayEquals(InetAddress.getByName("64:ff9b::").address,h.controller.nat64Prefix())
            assertEquals(0,h.shadow.propertyReads)
        }
    }
    @Test fun `DNS updates refresh cached resolvers without retiring flows`() {
        Harness().use { h ->
            h.changed(ipv6Properties())
            val generation=h.controller.currentGeneration()
            h.changed(ipv6Properties().apply { setDnsServers(listOf(InetAddress.getByName("1.1.1.1"))) })
            assertEquals(listOf(InetAddress.getByName("1.1.1.1")),h.controller.currentDnsServers())
            assertTrue(h.controller.ipv6Available())
            assertEquals(generation,h.controller.currentGeneration())
            assertFalse(h.tcp.isClosed); assertFalse(h.udp.isClosed)
            assertEquals(0,h.shadow.propertyReads)
        }
    }
    @Test fun `NAT64 updates immediately deny embedded private destinations`() {
        Harness().use { h ->
            h.changed(ipv6Properties())
            val destination=InetAddress.getByName("2001:4860:64::a00:1")
            h.controller.requireAllowed(destination)
            h.changed(ipv6Properties().apply { nat64Prefix=prefix("2001:4860:64::",96) })
            assertThrows(io.droidbridge.policy.DestinationDeniedException::class.java) { h.controller.requireAllowed(destination) }
            assertTrue(h.tcp.isClosed); assertTrue(h.udp.isClosed)
            assertEquals(0,h.shadow.propertyReads)
        }
    }
    @Test fun `replacement loss and unregister invalidate properties and fence stale callbacks`() {
        Harness().use { h ->
            h.changed(ipv6Properties())
            val old=AndroidNetworkHandle(h.network)
            val second=ShadowNetwork.newInstance(43)
            h.shadow.callback.onAvailable(second)
            assertFalse(h.controller.ipv6Available())
            assertNull(h.transport.nat64Prefix(old)); assertTrue(h.transport.dnsServers(old).isEmpty())
            h.shadow.callback.onLinkPropertiesChanged(h.network,ipv6Properties())
            assertFalse(h.controller.ipv6Available())
            h.shadow.callback.onLinkPropertiesChanged(second,ipv6Properties())
            assertTrue(h.controller.ipv6Available())
            h.shadow.callback.onLost(second)
            assertFalse(h.transport.supportsIpv6(AndroidNetworkHandle(second)))
            h.shadow.callback.onAvailable(second)
            assertFalse(h.controller.ipv6Available())
            h.shadow.callback.onLinkPropertiesChanged(second,ipv6Properties())
            val stale=h.shadow.callback
            h.controller.stop(); h.controller.start(); h.shadow.callback.onAvailable(second)
            stale.onAvailable(second); stale.onLinkPropertiesChanged(second,ipv6Properties())
            assertFalse(h.controller.ipv6Available())
            assertNull(h.controller.nat64Prefix()); assertTrue(h.controller.currentDnsServers().isEmpty())
            assertEquals(0,h.shadow.propertyReads)
        }
    }
    @Test fun `initial identical reordered and metadata callbacks retain established sockets and generation`() {
        Harness().use { h ->
            val generation=h.controller.currentGeneration(); val losses=h.losses
            h.changed(properties())
            assertFalse("initial LinkProperties must only seed the baseline",h.tcp.isClosed)
            val metadata=properties(reversed=true).apply {
                setDnsServers(listOf(InetAddress.getByName("8.8.8.8")))
                domains="example.test"
                httpProxy=ProxyInfo.buildDirectProxy("proxy.test",8080)
            }
            h.changed(properties()); h.changed(properties(reversed=true)); h.changed(metadata)
            // Private DNS has no public setter; use a framework fixture mutation only in the test.
            ReflectionHelpers.callInstanceMethod<Void>(metadata,"setUsePrivateDns",ClassParameter.from(Boolean::class.javaPrimitiveType!!,true))
            ReflectionHelpers.callInstanceMethod<Void>(metadata,"setPrivateDnsServerName",ClassParameter.from(String::class.java,"dns.example.test"))
            h.changed(metadata)
            assertFalse(h.tcp.isClosed); assertFalse(h.udp.isClosed)
            assertEquals(generation,h.controller.currentGeneration()); assertEquals(losses,h.losses)
            assertEquals(1,h.events.size)
        }
    }
    @Test fun `each public transport identity change retires TCP and association and rejects stale generation`() {
        val changes=listOf<(LinkProperties)->Unit>(
            { it.interfaceName="rmnet1" },
            { it.setLinkAddresses(listOf(address("192.0.2.3",24),address("2001:db8::2",64))) },
            { it.setLinkAddresses(listOf(address("192.0.2.2",25),address("2001:db8::2",64))) },
            { it.setLinkAddresses(listOf(address("192.0.2.2",24))) },
            { it.addRoute(route("198.51.100.0",24)) },
            { it.addRoute(route(gateway="192.0.2.9")) },
            { it.addRoute(route(type=RouteInfo.RTN_UNREACHABLE)) },
            { it.nat64Prefix=prefix("2001:db8:64::",96) },
            { it.nat64Prefix=null },
        )
        for((index,change) in changes.withIndex()) Harness().use { h ->
            h.changed(properties())
            val before=h.controller.snapshot(); val losses=h.losses
            assertFalse("baseline closed sockets for case $index",h.tcp.isClosed)
            h.changed(properties().also(change))
            assertTrue("TCP was retained for case $index",h.tcp.isClosed)
            assertTrue("association was retained for case $index",h.udp.isClosed)
            assertEquals(before.generation+1,h.controller.currentGeneration()); assertEquals(losses+1,h.losses)
            try { h.controller.requireCurrent(before); fail("old generation remained usable") } catch(_: CellularUnavailableException) {}
            val late=DatagramSocket(null as SocketAddress?)
            try { h.controller.track(before,late); fail("late open was accepted") } catch(_: CellularUnavailableException) {}
            assertTrue("late open was not closed for case $index",late.isClosed)
        }
    }
    @Test fun `repeated availability preserves baseline while stop discards old callback`() {
        Harness().use { h ->
            h.changed(properties())
            val generation=h.controller.currentGeneration()
            h.shadow.callback.onAvailable(ShadowNetwork.newInstance(42))
            assertFalse(h.tcp.isClosed); assertEquals(generation,h.controller.currentGeneration())
            h.changed(properties().apply { interfaceName="rmnet1" })
            assertTrue(h.tcp.isClosed); assertEquals(generation+1,h.controller.currentGeneration())
            val oldCallback=h.shadow.callback
            h.controller.stop(); h.controller.start()
            h.shadow.callback.onAvailable(h.network)
            val fresh=DatagramSocket(null as SocketAddress?)
            h.controller.track(h.controller.snapshot(),fresh)
            val restartedGeneration=h.controller.currentGeneration()
            oldCallback.onLinkPropertiesChanged(h.network,properties().apply { interfaceName="stale" })
            oldCallback.onLost(h.network)
            h.changed(properties())
            assertFalse(fresh.isClosed); assertEquals(restartedGeneration,h.controller.currentGeneration())
        }
    }
    @Test fun `network replacement and loss still retire while stale callbacks cannot seed new network`() {
        Harness().use { h ->
            h.changed(properties())
            val second=ShadowNetwork.newInstance(43)
            h.shadow.callback.onAvailable(second)
            assertTrue(h.tcp.isClosed); assertTrue(h.udp.isClosed)
            val replacement=DatagramSocket(null as SocketAddress?)
            h.controller.track(h.controller.snapshot(),replacement)
            val generation=h.controller.currentGeneration()
            h.shadow.callback.onLinkPropertiesChanged(h.network,properties().apply { interfaceName="stale" })
            h.shadow.callback.onLost(h.network)
            h.shadow.callback.onLinkPropertiesChanged(second,properties())
            assertFalse(replacement.isClosed); assertEquals(generation,h.controller.currentGeneration())
            h.shadow.callback.onLost(second)
            assertTrue(replacement.isClosed); assertEquals(generation+1,h.controller.currentGeneration())
        }
    }
}
