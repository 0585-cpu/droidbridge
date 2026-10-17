package io.droidbridge.usb

import android.content.Context
import android.content.Intent
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import org.robolectric.shadow.api.Shadow
import org.robolectric.shadows.ShadowPowerManager
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34], shadows = [UsbAccessorySessionTest.AccessoryShadow::class, UsbAccessorySessionTest.ManagerShadow::class])
class UsbAccessorySessionTest {
    @Test fun connectAndDetachDuringRecoveryNeverUsePermissionGatedSerialOrAccessoryEquality() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(UsbManager::class.java)
        val managerShadow = Shadow.extract<ManagerShadow>(manager)
        val power = context.getSystemService(PowerManager::class.java)
        shadowOf(power).setIsInteractive(false)
        val accessory = Shadow.newInstanceOf(UsbAccessory::class.java)
        val detachParcel = Shadow.newInstanceOf(UsbAccessory::class.java)
        @Suppress("DEPRECATION")
        context.sendStickyBroadcast(Intent("android.hardware.usb.action.USB_STATE")
            .putExtra("connected", true).putExtra("configured", true).putExtra("accessory", true))
        val pipe = ParcelFileDescriptor.createPipe()
        managerShadow.attached = accessory
        managerShadow.descriptor = pipe[0]
        UsbAccessorySession(context, manager, power).use { session ->
            pipe[1].use {
                session.connect(accessory)
                // Robolectric's createPipe() is an empty regular file. Its real reader reaches
                // EOF immediately, so test this deterministic recovery state, not a race against
                // the bootstrap wake lock being released. Active lease ownership is covered by
                // UsbSessionResourcesTest; active descriptor reuse by UsbAccessoryRecoveryTest.
                val recoveryDeadline = System.nanoTime() + 2_000_000_000L
                while (!UsbAccessoryStatus.state.value.startsWith("USB interrupted") && System.nanoTime() < recoveryDeadline) Thread.sleep(1)
                assertTrue(UsbAccessoryStatus.state.value.startsWith("USB interrupted"))
                val wakeLock = ShadowPowerManager.getLatestWakeLock()
                assertTrue(wakeLock.isHeld)
                session.connect(accessory)
                assertEquals(1, managerShadow.opens, "Repeated connect must retain its existing descriptor")
                managerShadow.permitted = false
                managerShadow.attached = null
                session.detached(detachParcel)
                assertFalse(wakeLock.isHeld, "Detach after permission revocation must release the session")
                assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld, "Detach must cancel any recovery lease")
                assertFalse(power.isInteractive)
            }
        }
    }

    @Test fun permissionWithoutPhysicalPresenceCannotOpenAnAccessory() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(UsbManager::class.java)
        val managerShadow = Shadow.extract<ManagerShadow>(manager)
        val power = context.getSystemService(PowerManager::class.java)
        val accessory = Shadow.newInstanceOf(UsbAccessory::class.java)
        UsbAccessorySession(context, manager, power).use { session ->
            assertFailsWith<IllegalStateException> { session.connect(accessory) }
            assertEquals(0, managerShadow.opens)
        }
    }

    @Test fun chargingModeCannotOpenStaleAccessoryEvenWithPermission() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(UsbManager::class.java)
        val platform = Shadow.extract<ManagerShadow>(manager)
        val accessory = Shadow.newInstanceOf(UsbAccessory::class.java)
        platform.attached = accessory
        @Suppress("DEPRECATION")
        context.sendStickyBroadcast(Intent("android.hardware.usb.action.USB_STATE")
            .putExtra("connected", true).putExtra("configured", true).putExtra("accessory", false))
        UsbAccessorySession(context, manager).use { session ->
            runCatching { session.connect(accessory) }
            assertEquals(0, platform.opens, "Stale accessoryList must not retain /dev/usb_accessory in charging mode")
        }
    }

    @Test fun modeExitDuringOpenClosesReturnedDescriptorBeforeStartingIo() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val manager = context.getSystemService(UsbManager::class.java)
        val platform = Shadow.extract<ManagerShadow>(manager)
        val accessory = Shadow.newInstanceOf(UsbAccessory::class.java)
        platform.attached = accessory
        fun mode(accessoryMode: Boolean) {
            @Suppress("DEPRECATION")
            context.sendStickyBroadcast(Intent("android.hardware.usb.action.USB_STATE")
                .putExtra("connected", true).putExtra("configured", true).putExtra("accessory", accessoryMode))
        }
        mode(true)
        val pipe = ParcelFileDescriptor.createPipe()
        platform.descriptor = pipe[0]
        platform.beforeReturn = { mode(false) }
        pipe[1].use {
            UsbAccessorySession(context, manager).use { session ->
                session.connect(accessory)
                assertFalse(ShadowPowerManager.getLatestWakeLock().isHeld,
                    "Mode exit during open must not retain USB ownership or the CPU wake lock")
                assertFalse(pipe[0].fileDescriptor.valid())
                runCatching { session.connect(accessory) }
                assertEquals(1, platform.opens, "A stale accessory must not reopen after mode exit")
            }
        }
    }

    @Implements(UsbAccessory::class)
    class AccessoryShadow {
        @Implementation fun getManufacturer() = "DroidBridge"
        @Implementation fun getModel() = "DroidBridge USB"
        @Implementation fun getDescription() = "USB relay"
        @Implementation fun getVersion() = "1"
        @Implementation fun getUri() = "https://droidbridge.io"
        @Implementation fun getSerial(): String = throw SecurityException("USB permission revoked")
        @Implementation override fun equals(other: Any?): Boolean = throw SecurityException("equals reads serial")
    }

    @Implements(UsbManager::class)
    class ManagerShadow {
        var attached: UsbAccessory? = null
        var descriptor: ParcelFileDescriptor? = null
        var permitted = true
        var opens = 0
        var beforeReturn: () -> Unit = {}
        @Implementation fun hasPermission(accessory: UsbAccessory) = permitted
        @Implementation fun getAccessoryList(): Array<UsbAccessory>? = attached?.let { arrayOf(it) }
        @Implementation fun openAccessory(accessory: UsbAccessory): ParcelFileDescriptor? {
            opens++
            beforeReturn()
            return descriptor
        }
    }
}
