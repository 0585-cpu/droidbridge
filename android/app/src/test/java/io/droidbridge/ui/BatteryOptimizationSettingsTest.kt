package io.droidbridge.ui

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.os.PowerManager
import android.provider.Settings
import androidx.test.core.app.ApplicationProvider
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class BatteryOptimizationSettingsTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val power = context.getSystemService(PowerManager::class.java)

    private class SettingsContext(base: Context, val failure: (Intent) -> RuntimeException? = { null }) : ContextWrapper(base) {
        val launched = mutableListOf<Intent>()
        val attempted = mutableListOf<Intent>()
        override fun startActivity(intent: Intent) {
            attempted += intent
            failure(intent)?.let { throw it }
            launched += intent
        }
    }

    @Test fun requestTargetsThisAppButNeverTreatsOpeningDialogAsApproval() {
        val launcher = SettingsContext(context)
        val settings = BatteryOptimizationSettings(launcher)
        settings.request()
        assertEquals("android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS", launcher.launched.single().action)
        assertEquals("package:io.droidbridge.android", launcher.launched.single().dataString)
        assertEquals(false, settings.state.isExempt)
        // User cancels the system dialog: resuming must not open another prompt.
        settings.refresh()
        settings.refresh()
        assertEquals(1, launcher.launched.size)
        assertEquals(false, settings.state.isExempt)
    }

    @Test fun returningFromSettingsReflectsGrantAndLaterRevocation() {
        val launcher = SettingsContext(context)
        val settings = BatteryOptimizationSettings(launcher)
        shadowOf(power).setIgnoringBatteryOptimizations(context.packageName, true)
        settings.refresh()
        assertEquals(true, settings.state.isExempt)
        shadowOf(power).setIgnoringBatteryOptimizations(context.packageName, false)
        settings.refresh()
        assertEquals(false, settings.state.isExempt)
        assertTrue(launcher.launched.isEmpty(), "Refreshing lifecycle state must never prompt")
    }

    @Test fun alreadyExemptDoesNotRequestAgain() {
        shadowOf(power).setIgnoringBatteryOptimizations(context.packageName, true)
        val launcher = SettingsContext(context)
        val settings = BatteryOptimizationSettings(launcher)
        settings.request()
        assertEquals(true, settings.state.isExempt)
        assertTrue(launcher.launched.isEmpty())
    }

    @Test fun unsupportedRequestFallsBackToBatterySettings() {
        val launcher = SettingsContext(context) {
            if (it.action == Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS) ActivityNotFoundException() else null
        }
        val settings = BatteryOptimizationSettings(launcher)
        settings.request()
        assertEquals("android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS", launcher.launched.single().action)
        assertFalse(settings.state.settingsUnavailable)
        assertEquals(false, settings.state.isExempt)
    }

    @Test fun deniedRequestFallsBackAndUnavailableSettingsAreVisibleWithoutCrashing() {
        val launcher = SettingsContext(context) { SecurityException("settings unavailable") }
        val settings = BatteryOptimizationSettings(launcher)
        settings.request()
        assertTrue(settings.state.settingsUnavailable)
        assertEquals(false, settings.state.isExempt)
        assertTrue(launcher.launched.isEmpty())
        assertEquals(listOf("android.settings.REQUEST_IGNORE_BATTERY_OPTIMIZATIONS",
            "android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS"), launcher.attempted.map { it.action })
    }
}
