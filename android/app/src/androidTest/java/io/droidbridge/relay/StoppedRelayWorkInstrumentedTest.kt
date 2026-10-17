package io.droidbridge.relay
import io.droidbridge.network.*
import io.droidbridge.security.InMemoryPairingSecretStore
import java.net.*
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.junit.Test
import org.junit.runner.RunWith
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlin.test.assertEquals
import kotlin.test.assertTrue

@RunWith(AndroidJUnit4::class)
class StoppedRelayWorkInstrumentedTest {
    @Test fun periodicMetricsWorkExistsOnlyDuringAStartedRun(): Unit = runBlocking {
        val facade=object : ConnectivityFacade {
            override fun requestCellular(callback: CellularCallback) {}
            override fun unregister(callback: CellularCallback) {}
            override fun resolve(network: NetworkHandle,domain: String)=emptyList<InetAddress>()
            override fun createSocket(network: NetworkHandle)=Socket()
            override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
        }
        val relay=RelayServiceController(InMemoryPairingSecretStore(),CellularNetworkController(facade),relayPort=0)
        val server=relay.javaClass.getDeclaredField("server").apply { isAccessible=true }.get(relay) as RelayServer
        try {
            delay(100) // let construction finish
            server.metrics.addTransfer(1,0)
            delay(1200)
            assertEquals(0L,relay.metrics.value.uploadedBytes,"Stopped controller still runs its periodic publisher")
            relay.start()
            withTimeout(1500) { relay.metrics.first { it.uploadedBytes==1L } }
            server.metrics.addTransfer(1_000_000,2_000_000)
            withTimeout(2500) { relay.metrics.first { it.uploadBytesPerSecond>1000 && it.downloadBytesPerSecond>1000 } }
            relay.stop()
            assertEquals(0L,relay.metrics.value.uploadBytesPerSecond,"Stopped transfer rate must be zero without another timer tick")
            assertEquals(0L,relay.metrics.value.downloadBytesPerSecond)
            server.metrics.addTransfer(2,0)
            delay(1200)
            assertEquals(1_000_001L,relay.metrics.value.uploadedBytes,"Stop failed to cancel periodic work")
            server.metrics.flowOpened()
            server.metrics.flowClosed()
            assertEquals(0L,relay.metrics.value.uploadBytesPerSecond,"Late flow cleanup must not restart stopped rate sampling")
            relay.start()
            withTimeout(1500) { relay.metrics.first { it.uploadedBytes==1_000_003L } }
            assertTrue(relay.metrics.value.uploadBytesPerSecond<1000,"Restart must not reuse the previous run's rate")
        } finally { relay.stop(); relay.shutdown() }
    }
}
