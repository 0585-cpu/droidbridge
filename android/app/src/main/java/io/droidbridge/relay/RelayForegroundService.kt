package io.droidbridge.relay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.BroadcastReceiver
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import androidx.core.content.ContextCompat
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import io.droidbridge.R
import io.droidbridge.state.RelayStatus
import io.droidbridge.usb.UsbAccessorySession
import io.droidbridge.usb.UsbAccessoryStatus
import io.droidbridge.usb.UsbAccessoryAvailability
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Foreground service (connectedDevice). Started only by an explicit user Start action. */
class RelayForegroundService : Service() {
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private lateinit var controller: RelayServiceController
    private var notificationUpdates: Job? = null
    private lateinit var usb: UsbAccessorySession
    private var usbRequested = false
    private val detached = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == UsbManager.ACTION_USB_ACCESSORY_DETACHED) {
                @Suppress("DEPRECATION")
                val accessory = intent.getParcelableExtra<UsbAccessory>(UsbManager.EXTRA_ACCESSORY)
                accessory?.let(usb::detached)
            } else if (intent.action == UsbAccessoryAvailability.ACTION_USB_STATE) {
                usb.usbStateChanged()
                // Continue the user's existing USB request after re-enumeration, only with
                // the actual current permission and mode. Never request a new grant here.
                if (usbRequested && UsbAccessoryAvailability.read(context).canOpen) {
                    val manager = getSystemService(UsbManager::class.java)
                    manager.accessoryList?.firstOrNull { UsbAccessoryStatus.matches(it) && manager.hasPermission(it) }
                        ?.let { accessory ->
                            runCatching { usb.connect(accessory) }.onFailure {
                                Log.w("DroidBridgeUSB", "USB mode changed during reconnect", it)
                            }
                        }
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        controller = RelayServiceController.shared(applicationContext)
        usb = UsbAccessorySession(applicationContext, relayAcceptor = controller::acceptRelay)
        ContextCompat.registerReceiver(this, detached, IntentFilter(UsbManager.ACTION_USB_ACCESSORY_DETACHED).apply {
            addAction(UsbAccessoryAvailability.ACTION_USB_STATE)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START, ACTION_CONNECT_USB -> {
                startForegroundCompat(buildNotification(RelayStatus.STARTING, 0, 0, 0))
                try {
                    controller.start()
                    if (intent.action == ACTION_CONNECT_USB) {
                        usbRequested = true
                        @Suppress("DEPRECATION")
                        val accessory = intent.getParcelableExtra<UsbAccessory>(UsbManager.EXTRA_ACCESSORY)
                            ?: error("USB accessory is missing")
                        usb.connect(accessory)
                    }
                } catch (error: Exception) {
                    Log.e("DroidBridgeUSB", "Cannot start relay or USB session", error)
                    UsbAccessoryStatus.mutable.value = error.message ?: "Cannot start USB relay"
                    usb.close()
                    controller.stop()
                    stopSelf()
                    return START_NOT_STICKY
                }
                notificationUpdates?.cancel()   // a repeated Start must not stack collectors
                notificationUpdates = scope.launch {
                    controller.state.collectLatest { state ->
                        val metrics = controller.metrics.value
                        notificationManager().notify(NOTIFICATION_ID,
                            buildNotification(state.relayStatus, metrics.activeFlows, metrics.uploadedBytes, metrics.downloadedBytes))
                    }
                }
            }
            ACTION_STOP -> {
                usbRequested = false
                usb.close()
                controller.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        unregisterReceiver(detached)
        usb.close()
        // The relay is process-wide and shared with the UI: stop it, but keep it usable for the
        // next Start (shutting down its scope here would break every later start).
        controller.stop()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildNotification(status: RelayStatus, flows: Int, up: Long, down: Long): Notification {
        val text = when (status) {
            RelayStatus.BLOCKED_CELLULAR -> getString(R.string.status_blocked_cellular)
            else -> "${getString(R.string.status_running)} · flows $flows · ↑$up ↓$down"
        }
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle(getString(R.string.app_name))
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .build()
    }

    private fun createChannel() {
        val channel = NotificationChannel(CHANNEL_ID, getString(R.string.notification_channel), NotificationManager.IMPORTANCE_LOW)
        notificationManager().createNotificationChannel(channel)
    }

    private fun notificationManager() = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    companion object {
        const val ACTION_START = "io.droidbridge.action.START"
        const val ACTION_CONNECT_USB = "io.droidbridge.action.CONNECT_USB"
        const val ACTION_STOP = "io.droidbridge.action.STOP"
        private const val CHANNEL_ID = "droidbridge.relay"
        private const val NOTIFICATION_ID = 1
    }
}
