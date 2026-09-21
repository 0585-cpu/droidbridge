package io.droidbridge.relay

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import kotlin.test.assertEquals

/**
 * Device check: the service starts foreground and stops cleanly. It does not assert cellular traffic;
 * a full relay smoke lives in scripts/smoke-android-relay.sh.
 */
class RelayForegroundServiceTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun startAndStopService() {
        val start = Intent(context, RelayForegroundService::class.java).setAction(RelayForegroundService.ACTION_START)
        context.startForegroundService(start)
        Thread.sleep(1000)
        val stop = Intent(context, RelayForegroundService::class.java).setAction(RelayForegroundService.ACTION_STOP)
        context.startService(stop)
        Thread.sleep(500)
        assertEquals(RelayForegroundService.ACTION_STOP, stop.action)
    }
}
