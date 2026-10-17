package io.droidbridge.ui

import android.content.Context
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.PowerManager
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

data class BatteryOptimizationState(val isExempt: Boolean? = null, val settingsUnavailable: Boolean = false)

internal class BatteryOptimizationSettings(private val context: Context) {
    var state by mutableStateOf(BatteryOptimizationState())
        private set

    // Read the system on resume; opening/cancelling the settings screen grants nothing.
    fun refresh() {
        val exempt = try {
            context.getSystemService(PowerManager::class.java)?.isIgnoringBatteryOptimizations(context.packageName)
        } catch (_: SecurityException) { null }
        state = state.copy(isExempt = exempt, settingsUnavailable = state.settingsUnavailable && exempt != true)
    }

    // Only the visible settings button calls this. Never prompt from a service or on resume.
    fun request() {
        refresh()
        if (state.isExempt == true) return
        val opened = launch(Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"))) ||
            launch(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        state = state.copy(settingsUnavailable = !opened)
    }

    private fun launch(intent: Intent): Boolean = try {
        context.startActivity(intent)
        true
    } catch (_: ActivityNotFoundException) {
        false
    } catch (_: SecurityException) {
        false
    }
}
