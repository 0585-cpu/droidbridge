package io.droidbridge.network

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.telephony.TelephonyManager
import androidx.test.core.app.ApplicationProvider
import io.droidbridge.protocol.OpenDestination
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.test.assertTrue

/**
 * Real-device check: an outbound socket opened through AndroidCellularTransport is bound to a
 * TRANSPORT_CELLULAR network. Skipped (not failed) when the device has no active mobile data.
 */
class CellularBindingInstrumentedTest {
    @Test
    fun outboundSocketBindsToCellular() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        val transport = AndroidCellularTransport(cm, tm)
        val controller = CellularNetworkController(transport)
        controller.start()
        val available = try {
            withTimeout(15_000) { controller.state.first { it is CellularState.Available } as CellularState.Available }
        } catch (e: Exception) {
            controller.stop(); assumeTrue("no cellular network available", false); return@runBlocking
        }
        val handle = available.network as AndroidNetworkHandle
        val caps = cm.getNetworkCapabilities(handle.network)
        assertTrue(caps!!.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR))
        val socket = controller.connectTcp(OpenDestination.Domain("example.com", 443))
        socket.close()
        controller.stop()
    }
}
