package io.droidbridge

import android.os.Bundle
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.UsbManager
import androidx.core.content.ContextCompat
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.Surface
import androidx.lifecycle.viewmodel.compose.viewModel
import io.droidbridge.ui.RelayScreen
import io.droidbridge.ui.RelayViewModel
import io.droidbridge.ui.DroidBridgeTheme
import io.droidbridge.ui.BatteryOptimizationSettings
import io.droidbridge.relay.RelayForegroundService
import io.droidbridge.usb.UsbAccessoryStatus
import io.droidbridge.usb.UsbAccessoryAvailability

class MainActivity : ComponentActivity() {
    private val batterySettings by lazy { BatteryOptimizationSettings(this) }
    private val permissionAction get() = "$packageName.USB_PERMISSION"
    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != permissionAction) return
            // Re-enumerate and check the actual grant; never trust broadcast extras as authority.
            if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) connectUSB(false)
            else UsbAccessoryStatus.mutable.value = "USB 접근이 거부되었습니다. 연결 화면에서 다시 시도해 주세요."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ContextCompat.registerReceiver(this, permissionReceiver, IntentFilter(permissionAction), ContextCompat.RECEIVER_NOT_EXPORTED)
        setContent {
            DroidBridgeTheme {
                Surface {
                    val vm: RelayViewModel = viewModel(factory = RelayViewModelFactory(applicationContext))
                    RelayScreen(vm, onConnectUSB = { connectUSB(true) },
                        batteryState = batterySettings.state, onBatterySettings = batterySettings::request)
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        batterySettings.refresh()
        connectUSB(false)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        connectUSB(false)
    }

    private fun connectUSB(requestPermission: Boolean) {
        if (!UsbAccessoryAvailability.read(this).canOpen) {
            if (requestPermission) UsbAccessoryStatus.mutable.value = "Mac에서 USB 연결을 시작해 주세요."
            return
        }
        val manager = getSystemService(UsbManager::class.java)
        val accessory = manager.accessoryList?.firstOrNull(UsbAccessoryStatus::matches)
        if (accessory == null) {
            if (requestPermission) UsbAccessoryStatus.mutable.value = "Mac에서 이 휴대폰을 선택하고 연결을 준비해 주세요."
            return
        }
        if (manager.hasPermission(accessory)) {
            ContextCompat.startForegroundService(this, Intent(this, RelayForegroundService::class.java)
                .setAction(RelayForegroundService.ACTION_CONNECT_USB)
                .putExtra(UsbManager.EXTRA_ACCESSORY, accessory))
        } else if (requestPermission) {
            manager.requestPermission(accessory, PendingIntent.getBroadcast(this, 0,
                Intent(permissionAction).setPackage(packageName), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        } else {
            UsbAccessoryStatus.mutable.value = "USB 접근을 허용하려면 연결 화면의 버튼을 누르세요."
        }
    }

    override fun onDestroy() {
        unregisterReceiver(permissionReceiver)
        super.onDestroy()
    }
}
