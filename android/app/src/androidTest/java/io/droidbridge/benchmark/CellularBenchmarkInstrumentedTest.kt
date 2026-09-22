package io.droidbridge.benchmark

import android.content.Context
import android.net.ConnectivityManager
import android.os.Bundle
import android.telephony.TelephonyManager
import androidx.test.core.app.ApplicationProvider
import androidx.test.platform.app.InstrumentationRegistry
import io.droidbridge.network.AndroidCellularTransport
import io.droidbridge.network.CellularNetworkController
import io.droidbridge.network.CellularState
import io.droidbridge.protocol.OpenDestination
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.SecureRandom
import java.util.Locale
import kotlin.math.ceil
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Test
import kotlin.test.assertContentEquals

/** Direct-cellular RTT baseline for tools/b1_benchmark.py's DBB1 protocol. */
class CellularBenchmarkInstrumentedTest {
    @Test
    fun directCellularRttBaseline() = runBlocking {
        val arguments = InstrumentationRegistry.getArguments()
        val host = requireNotNull(arguments.getString("host")) { "-e host is required" }
        val port = requireNotNull(arguments.getString("port")?.toIntOrNull()) { "-e port is required" }
        require(port in 1..65535)

        val context = ApplicationProvider.getApplicationContext<Context>()
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        val controller = CellularNetworkController(AndroidCellularTransport(cm, tm))
        controller.start()
        try {
            withTimeout(15_000) { controller.state.first { it is CellularState.Available } }
            val socket = controller.connectTcp(OpenDestination.Domain(host, port))
            socket.soTimeout = 10_000
            socket.use {
                val input = DataInputStream(it.getInputStream())
                val output = DataOutputStream(it.getOutputStream())
                val random = SecureRandom()
                val samples = mutableListOf<Double>()
                repeat(35) { index ->
                    val nonce = random.nextLong()
                    val request = header(nonce)
                    val started = System.nanoTime()
                    output.write(request)
                    output.flush()
                    val response = ByteArray(request.size)
                    input.readFully(response)
                    val elapsedMs = (System.nanoTime() - started) / 1_000_000.0
                    assertContentEquals(request, response)
                    if (index >= 5) samples += elapsedMs
                }
                val ordered = samples.sorted()
                val median = ordered[ceil(ordered.size * 0.50).toInt() - 1]
                val p95 = ordered[ceil(ordered.size * 0.95).toInt() - 1]
                val result =
                    "{\"cellularBound\":true,\"medianRttMs\":${"%.3f".format(Locale.US, median)}," +
                        "\"p95RttMs\":${"%.3f".format(Locale.US, p95)}}"
                println("DROIDBRIDGE_BENCHMARK $result")
                InstrumentationRegistry.getInstrumentation().sendStatus(
                    0,
                    Bundle().apply { putString("droidbridgeBenchmark", result) },
                )
            }
        } finally {
            controller.stop()
        }
    }

    private fun header(nonce: Long): ByteArray =
        java.nio.ByteBuffer.allocate(21)
            .put(byteArrayOf('D'.code.toByte(), 'B'.code.toByte(), 'B'.code.toByte(), '1'.code.toByte()))
            .put(1.toByte()) // PING
            .putLong(0)
            .putLong(nonce)
            .array()
}
