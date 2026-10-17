package io.droidbridge.usb

import android.content.Context
import android.content.Intent
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import kotlin.test.assertEquals
import kotlin.test.assertFalse

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UsbAccessoryAvailabilityTest {
    @Test fun actualModeGatesOpenWhileTransientEnumerationDoesNotRetireAnActiveAccessory() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        // connected, configured, accessory, expected open, expected release
        val cases = listOf(
            listOf(true, true, true, true, false),
            listOf(true, true, false, false, true),
            listOf(false, false, true, false, true),
            listOf(true, false, true, false, false),
        )
        for (v in cases) {
            @Suppress("DEPRECATION")
            context.sendStickyBroadcast(Intent("android.hardware.usb.action.USB_STATE")
                .putExtra("connected", v[0]).putExtra("configured", v[1]).putExtra("accessory", v[2]))
            val state = UsbAccessoryAvailability.read(context)
            assertEquals(v[3], state.canOpen)
            assertEquals(v[4], state.mustRelease)
        }
    }
    @Test fun missingSystemStateNeverAuthorizesOpeningAStaleAccessory() {
        assertFalse(UsbAccessoryAvailability.read(ApplicationProvider.getApplicationContext()).canOpen)
    }
}
