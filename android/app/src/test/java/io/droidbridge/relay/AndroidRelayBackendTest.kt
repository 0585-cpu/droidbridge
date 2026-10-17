package io.droidbridge.relay

import android.net.Network
import android.system.Os
import android.system.OsConstants
import io.droidbridge.network.*
import io.droidbridge.protocol.Capability
import java.io.FileDescriptor
import java.net.InetAddress
import java.net.Socket
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadows.ShadowNetwork

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34],shadows=[AndroidRelayBackendTest.PingOsShadow::class,AndroidRelayBackendTest.BindingShadow::class])
class AndroidRelayBackendTest {
    // The real backend and ICMP probe own the policy/cache/lifecycle. Only native socket IO is
    // replaced: this host fixture cannot create or bind Android network-specific ping sockets.
    @Implements(Os::class)
    class PingOsShadow {
        companion object {
            val probes=mutableListOf<Int>()
            @JvmStatic @Implementation fun socket(domain: Int,type: Int,protocol: Int): FileDescriptor {
                require(type and OsConstants.SOCK_DGRAM != 0)
                require(protocol == if(domain==OsConstants.AF_INET) OsConstants.IPPROTO_ICMP else OsConstants.IPPROTO_ICMPV6)
                probes+=domain
                return FileDescriptor()
            }
            @JvmStatic @Implementation fun close(fd: FileDescriptor) {}
        }
    }
    @Implements(Network::class)
    class BindingShadow {
        @Implementation fun bindSocket(fd: FileDescriptor) {}
    }
    private class Facade: ConnectivityFacade {
        lateinit var callback: CellularCallback
        var ipv6=false
        override fun requestCellular(callback: CellularCallback) { this.callback=callback }
        override fun unregister(callback: CellularCallback) {}
        override fun resolve(network: NetworkHandle,domain: String)=emptyList<InetAddress>()
        override fun createSocket(network: NetworkHandle)=Socket()
        override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
        override fun supportsIpv6(network: NetworkHandle)=ipv6
    }
    @Before fun resetProbes() { PingOsShadow.probes.clear() }

    @Test fun `IPv6 readiness after initial capabilities enables ICMP6 without retiring IPv4 flows`() {
        val facade=Facade()
        val controller=CellularNetworkController(facade)
        val backend=AndroidRelayBackend(controller)
        controller.start()
        facade.callback.onAvailable(AndroidNetworkHandle(ShadowNetwork.newInstance(42)),null)
        Socket().use { existing ->
            controller.track(controller.snapshot(),existing)
            val generation=controller.currentGeneration()
            try {
                val initial=backend.capabilities()
                assertEquals(Capability.ICMP4,initial.flags and Capability.ICMP4)
                assertEquals(0L,initial.flags and Capability.ICMP6)
                facade.ipv6=true // First properties callback seeds readiness without a retirement.
                val ready=backend.capabilities()
                assertEquals(Capability.ICMP6,ready.flags and Capability.ICMP6)
                assertEquals(generation,ready.generation)
                assertFalse(existing.isClosed)
                val probes=PingOsShadow.probes.size
                repeat(32) { assertEquals(ready.flags,backend.capabilities().flags) }
                assertEquals("unchanged readiness must not probe on every capability request",probes,PingOsShadow.probes.size)
            } finally { controller.stop() }
        }
    }

    @Test fun `loss of IPv6 readiness removes cached ICMP6 support`() {
        val facade=Facade().apply { ipv6=true }
        val controller=CellularNetworkController(facade)
        val backend=AndroidRelayBackend(controller)
        controller.start()
        facade.callback.onAvailable(AndroidNetworkHandle(ShadowNetwork.newInstance(42)),null)
        try {
            assertEquals(Capability.ICMP6,backend.capabilities().flags and Capability.ICMP6)
            facade.ipv6=false
            val unavailable=backend.capabilities()
            assertEquals(0L,unavailable.flags and Capability.ICMP6)
            assertEquals(Capability.ICMP4,unavailable.flags and Capability.ICMP4)
        } finally { controller.stop() }
    }
}
