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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.lifecycle.viewmodel.compose.viewModel
import io.droidbridge.ui.RelayScreen
import io.droidbridge.ui.RelayViewModel
import io.droidbridge.relay.RelayForegroundService
import io.droidbridge.usb.UsbAccessoryStatus

class MainActivity : ComponentActivity() {
    private val permissionAction get() = "$packageName.USB_PERMISSION"
    private val permissionReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != permissionAction) return
            // Re-enumerate and check the actual grant; never trust broadcast extras as authority.
            if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) connectUSB(false)
            else UsbAccessoryStatus.mutable.value = "USB permission denied. Tap Connect USB to retry."
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        ContextCompat.registerReceiver(this, permissionReceiver, IntentFilter(permissionAction), ContextCompat.RECEIVER_NOT_EXPORTED)
        setContent {
            MaterialTheme {
                Surface {
                    val vm: RelayViewModel = viewModel(factory = RelayViewModelFactory(applicationContext))
                    RelayScreen(vm, onConnectUSB = { connectUSB(true) })
                }
            }
        }
    }

    override fun onResume() { super.onResume(); connectUSB(false) }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        connectUSB(false)
    }

    private fun connectUSB(requestPermission: Boolean) {
        val manager = getSystemService(UsbManager::class.java)
        val accessory = manager.accessoryList?.firstOrNull(UsbAccessoryStatus::matches)
        if (accessory == null) {
            if (requestPermission) UsbAccessoryStatus.mutable.value = "On the Mac, select this phone and choose Pair New Mac or Prepare Relay."
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
            UsbAccessoryStatus.mutable.value = "Tap Connect USB to grant access."
        }
    }

    override fun onDestroy() {
        unregisterReceiver(permissionReceiver)
        super.onDestroy()
    }
}
