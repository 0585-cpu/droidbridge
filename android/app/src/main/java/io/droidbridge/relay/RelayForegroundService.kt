package io.droidbridge.relay

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import io.droidbridge.R
import io.droidbridge.state.RelayStatus
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/** Foreground service (connectedDevice). Started only by an explicit user Start action. */
class RelayForegroundService : Service() {
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private lateinit var controller: RelayServiceController

    override fun onCreate() {
        super.onCreate()
        controller = RelayServiceController.create(applicationContext)
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                startForegroundCompat(buildNotification(RelayStatus.STARTING, 0, 0, 0))
                controller.start()
                scope.launch {
                    controller.state.collectLatest { state ->
                        val metrics = controller.metrics.value
                        notificationManager().notify(NOTIFICATION_ID,
                            buildNotification(state.relayStatus, metrics.activeFlows, metrics.uploadedBytes, metrics.downloadedBytes))
                    }
                }
            }
            ACTION_STOP -> {
                controller.stop()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        controller.stop()
        controller.shutdown()
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
        const val ACTION_STOP = "io.droidbridge.action.STOP"
        private const val CHANNEL_ID = "droidbridge.relay"
        private const val NOTIFICATION_ID = 1
    }
}
