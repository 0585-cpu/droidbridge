package io.droidbridge.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.telephony.TelephonyManager
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import io.droidbridge.protocol.OpenDestination
import java.net.DatagramPacket
import java.net.Inet4Address
import java.net.Inet6Address
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.test.assertTrue

/** Real-device tests. Missing cellular service/resolvers are explicit skips; failed traffic is not. */
class CellularBindingInstrumentedTest {
    @Test fun outboundSocketBindsToCellular() = runBlocking {
        withCellular { _, controller, _ ->
            val socket = controller.connectTcp(OpenDestination.Domain("example.com", 443))
            try { assertTrue(socket.isConnected) }
            finally { socket.close(); controller.release(socket) }
        }
    }

    @Test fun outboundUdpQueriesSelectedCellularDns() = runBlocking {
        withCellular { transport, controller, handle ->
            val servers = controller.currentDnsServers()
            assumeTrue("selected cellular network has no DNS resolvers", servers.isNotEmpty())
            // Fixed example.com A query, transaction ID DB; no device identifiers or IPs are logged.
            val query = byteArrayOf(0x44, 0x42, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 7) +
                "example".toByteArray(Charsets.US_ASCII) + byteArrayOf(3) +
                "com".toByteArray(Charsets.US_ASCII) + byteArrayOf(0, 0, 1, 0, 1)
            var answered = false
            val snapshot = controller.snapshot()
            for (server in servers.take(3)) {
                val socket = transport.createDatagramSocket(handle)
                try {
                    controller.track(snapshot, socket)
                    socket.soTimeout = 3000
                    socket.connect(server, 53)
                    socket.send(DatagramPacket(query, query.size))
                    val response = DatagramPacket(ByteArray(4096), 4096)
                    socket.receive(response)
                    controller.requireCurrent(snapshot)
                    val bytes = response.data.copyOf(response.length)
                    assertTrue(bytes.size >= 12, "cellular DNS response was too short")
                    assertTrue(DnsWire.transactionId(bytes) == 0x4442, "cellular DNS transaction ID mismatch")
                    assertTrue(DnsWire.isResponse(bytes), "cellular DNS response missing QR")
                    assertTrue(bytes[3].toInt() and 15 == 0, "cellular DNS returned an error")
                    answered = true
                    Log.i("DroidBridgeCellular", "udpDnsPassed=true family=${if (server is Inet6Address) 6 else 4}")
                    break
                } catch (_: java.io.IOException) {
                    // Try each supplied resolver; report a sanitized failure if none answered.
                } finally { socket.close(); controller.release(socket) }
            }
            assertTrue(answered, "No selected cellular DNS resolver answered the UDP query")
        }
    }

    private suspend fun withCellular(block: suspend (AndroidCellularTransport, CellularNetworkController, AndroidNetworkHandle) -> Unit) {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        val transport = AndroidCellularTransport(cm, tm)
        val controller = CellularNetworkController(transport)
        controller.start()
        try {
            val available = try {
                withTimeout(15_000) { controller.state.first { it is CellularState.Available } as CellularState.Available }
            } catch (_: kotlinx.coroutines.TimeoutCancellationException) {
                assumeTrue("no cellular network available", false)
                return
            }
            val handle = available.network as AndroidNetworkHandle
            val caps = cm.getNetworkCapabilities(handle.network)
            assertTrue(caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true)
            val properties = cm.getLinkProperties(handle.network)
            Log.i("DroidBridgeCellular", "ipv4Link=${properties?.linkAddresses?.any { it.address is Inet4Address } == true} " +
                "ipv6Link=${properties?.linkAddresses?.any { it.address is Inet6Address } == true} " +
                "ipv6Available=${controller.ipv6Available()} nat64Present=${controller.nat64Prefix() != null}")
            block(transport, controller, handle)
        } finally { controller.stop() }
    }
}
