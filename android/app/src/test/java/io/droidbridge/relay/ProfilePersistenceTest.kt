package io.droidbridge.relay

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import io.droidbridge.network.*
import io.droidbridge.security.InMemoryPairingSecretStore
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class ProfilePersistenceTest {
    @Test fun `profile survives store recreation and corrupt values restore defaults`() {
        val context=ApplicationProvider.getApplicationContext<Context>()
        val prefs=context.getSharedPreferences("profile-test",Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        val expected=TrafficProfile(SocketEgressPolicy(65,64),listOf("example.test"),12345,67890,8192)
        AndroidTrafficProfileStore(prefs).save(expected)
        assertEquals(expected,AndroidTrafficProfileStore(prefs).load())
        prefs.edit().putInt("ttl",999).commit()
        assertEquals(TrafficProfile(),AndroidTrafficProfileStore(prefs).load())
    }
    @Test fun `running relay refuses profile changes and next start snapshots saved settings`() {
        val facade=object: ConnectivityFacade {
            override fun requestCellular(callback: CellularCallback) {}
            override fun unregister(callback: CellularCallback) {}
            override fun resolve(network: NetworkHandle,domain: String)=emptyList<InetAddress>()
            override fun createSocket(network: NetworkHandle)=Socket()
            override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
        }
        val relay=RelayServiceController(InMemoryPairingSecretStore(),CellularNetworkController(facade),MemoryTrafficProfileStore(),relayPort=0)
        try {
            val first=TrafficProfile(socketPolicy=SocketEgressPolicy(ipv4Ttl=65))
            assertTrue(relay.updateProfile(first)); relay.start()
            assertFalse(relay.updateProfile(TrafficProfile()))
            assertEquals(first,relay.profile.value)
            relay.stop(); assertTrue(relay.updateProfile(TrafficProfile()))
        } finally { relay.stop(); relay.shutdown() }
    }
}
