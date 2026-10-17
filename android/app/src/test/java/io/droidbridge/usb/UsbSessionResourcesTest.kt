package io.droidbridge.usb

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class UsbSessionResourcesTest {
    private val power = ApplicationProvider.getApplicationContext<Context>()
        .getSystemService(PowerManager::class.java)

    @Test fun unusedAccessoryStartupLeaseExpires() {
        val pipe = ParcelFileDescriptor.createPipe()
        pipe[1].use {
            val resources = UsbSessionResources(pipe[0], power)
            try {
                val lock = ShadowPowerManager.getLatestWakeLock()
                org.robolectric.shadows.ShadowSystemClock.advanceBy(java.time.Duration.ofSeconds(20))
                assertFalse(lock.isHeld, "An accessory without a host must not hold the CPU indefinitely")
            } finally { resources.close() }
        }
    }
    @Test fun usbSessionKeepsCpuAwakeWithScreenOffAndReleasesOnClose() {
        shadowOf(power).setIsInteractive(false)
        val pipe = ParcelFileDescriptor.createPipe()
        pipe[1].use {
            val resources = UsbSessionResources(pipe[0], power)
            val lock = ShadowPowerManager.getLatestWakeLock()
            assertTrue(lock.isHeld, "USB IO must stay runnable while the screen is off")
            assertFalse(power.isInteractive, "Keeping the CPU awake must not turn on the screen")
            resources.close()
            assertFalse(lock.isHeld, "Closing USB must not leak the CPU wake lock")
            resources.close()
            assertFalse(lock.isHeld, "Repeated cleanup must be safe")
        }
    }

    @Test fun closingOldSessionDoesNotReleaseReplacementSession() {
        val first = ParcelFileDescriptor.createPipe()
        val second = ParcelFileDescriptor.createPipe()
        first[1].use { second[1].use {
            val old = UsbSessionResources(first[0], power)
            val oldLock = ShadowPowerManager.getLatestWakeLock()
            val replacement = UsbSessionResources(second[0], power)
            val newLock = ShadowPowerManager.getLatestWakeLock()
            try {
                old.close()
                old.close()
                assertFalse(oldLock.isHeld)
                assertTrue(newLock.isHeld, "Late old-session cleanup must not suspend new USB IO")
            } finally { replacement.close() }
            assertFalse(newLock.isHeld)
        } }
    }
}
