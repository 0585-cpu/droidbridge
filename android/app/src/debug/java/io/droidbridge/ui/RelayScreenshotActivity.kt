package io.droidbridge.ui

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import io.droidbridge.relay.TrafficProfile
import io.droidbridge.state.CellularStatus
import io.droidbridge.state.RelayStatus

/** Debug-only, synthetic screen for visual regression capture. It never starts the real service. */
class RelayScreenshotActivity : ComponentActivity() {
    private var uiState by mutableStateOf(RelayUiState())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val variant = intent.getStringExtra("variant")
        uiState = when (variant) {
            "ready", "settings" -> RelayUiState(
                relayStatus = if (variant == "settings") RelayStatus.STOPPED else RelayStatus.RUNNING,
                cellularStatus = if (variant == "settings") CellularStatus.UNAVAILABLE else CellularStatus.AVAILABLE,
                carrierName = "모바일 데이터",
                pairedMacName = "MacBook Pro",
                uploadedBytes = 1_540_000,
                downloadedBytes = 8_210_000,
                uploadRate = 42_000,
                downloadRate = 172_000,
                activeFlows = 4,
                activeUdp = 1,
            )
            else -> RelayUiState()
        }
        setContent {
            DroidBridgeTheme {
                RelayContent(
                    state = uiState,
                    usbStatus = if (variant == "setup") "USB disconnected" else "USB accessory connected",
                    initialTab = if (variant == "settings") 1 else 0,
                )
            }
        }
    }

    fun loadProfileForTest(profile: TrafficProfile) {
        uiState = uiState.copy(profile = profile)
    }
}
