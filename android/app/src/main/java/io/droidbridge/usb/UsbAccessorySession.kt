package io.droidbridge.usb

import android.content.Context
import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import android.os.PowerManager
import android.os.SystemClock
import android.util.Log
import java.io.BufferedInputStream
import java.io.Closeable
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object UsbAccessoryStatus {
    internal val mutable = MutableStateFlow("Connect USB, then select this phone in DroidBridge on the Mac.")
    val state = mutable.asStateFlow()
    fun matches(accessory: UsbAccessory) = accessory.manufacturer == "DroidBridge" && accessory.model == "DroidBridge USB"
}

/** Owned by the foreground service, never by an Activity or a Compose screen. */
class UsbAccessorySession(
    private val context: Context,
    private val manager: UsbManager = context.getSystemService(UsbManager::class.java),
    private val powerManager: PowerManager = context.getSystemService(PowerManager::class.java),
    private val relayAcceptor: ((java.net.Socket) -> Boolean)? = null,
) : Closeable {
    // Android exposes one attached accessory. Detach cancels that physical lifetime; these safe
    // fields compare its separately-parceled attach/list/detach descriptions. Never use equals or
    // serial: UsbAccessory.equals reads serial, which can throw after USB permission is revoked.
    private data class Identity(
        val manufacturer: String?, val model: String?, val description: String?,
        val version: String?, val uri: String?,
    ) {
        constructor(accessory: UsbAccessory) : this(accessory.manufacturer, accessory.model,
            accessory.description, accessory.version, accessory.uri)
    }

    private val scheduler = ScheduledThreadPoolExecutor(1) { work ->
        Thread(work, "aoa-reopen").apply { isDaemon = true }
    }.apply {
        removeOnCancelPolicy = true
        setKeepAliveTime(1, TimeUnit.SECONDS)
        // No thread remains owned by an idle/stopped service after its last task is removed.
        allowCoreThreadTimeOut(true)
    }

    private val recovery = UsbAccessoryRecovery<Identity>(
        eligible = { findPermitted(it) != null },
        open = ::open,
        schedule = { delay, work ->
            val task = scheduler.schedule(work, delay, TimeUnit.MILLISECONDS)
            Closeable { task.cancel(false) }
        },
        holdRecovery = { timeout ->
            val lock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DroidBridge:UsbRecovery")
            lock.setReferenceCounted(false)
            // Keeps 1/2/4 s retries runnable with the screen off. Even a stuck platform open
            // cannot retain this lease beyond the controller's entire recovery window.
            lock.acquire(timeout)
            Closeable { if (lock.isHeld) lock.release() }
        },
        nowMillis = SystemClock::elapsedRealtime,
        status = {
            UsbAccessoryStatus.mutable.value = it
            Log.i("DroidBridgeUSB", it)
        },
    )

    fun connect(selected: UsbAccessory) {
        check(UsbAccessoryAvailability.read(context).canOpen) { "USB accessory mode is not ready. Connect from the Mac first." }
        require(UsbAccessoryStatus.matches(selected)) { "This accessory belongs to another app." }
        check(manager.hasPermission(selected)) { "Allow DroidBridge to access USB on the phone." }
        recovery.connect(Identity(selected))
    }

    fun detached(selected: UsbAccessory) = recovery.detached(Identity(selected))

    fun usbStateChanged() {
        // Read the latest sticky system state: a queued old broadcast must not retire a new session.
        if (UsbAccessoryAvailability.read(context).mustRelease) recovery.close()
    }

    override fun close() = recovery.close()

    private fun findPermitted(identity: Identity): UsbAccessory? {
        if (!UsbAccessoryAvailability.read(context).canOpen) return null
        return manager.accessoryList?.firstOrNull {
            UsbAccessoryStatus.matches(it) && Identity(it) == identity && manager.hasPermission(it)
        }
    }

    private fun open(identity: Identity, onClosed: (String) -> Unit): UsbAccessoryRecovery.Session {
        val selected = findPermitted(identity) ?: error("USB accessory detached or permission revoked")
        val descriptor = manager.openAccessory(selected) ?: error("Cannot open USB accessory. Reconnect the cable.")
        var resources: UsbSessionResources? = null
        var reliable: ReliableAccessoryChannel? = null
        try {
            val owned = UsbSessionResources(descriptor, powerManager)
            resources = owned
            // Buffered reads are essential: short reads directly on the USB descriptor can drop data.
            val rawInput = AccessoryReadTrace(FileInputStream(descriptor.fileDescriptor), fingerprints =
                context.getSharedPreferences("diagnostics", Context.MODE_PRIVATE).getBoolean("usb_read_fingerprints", false))
            val input = BufferedInputStream(rawInput, AoaFrame.MAX_PAYLOAD)
            val output = FileOutputStream(descriptor.fileDescriptor)
            val bridgeOwner = AtomicReference<AoaAccessoryBridge?>()
            val channel = ReliableAccessoryChannel(input, output, closeTransport = { owned.close() },
                onClosed = { retries, reason ->
                    Log.i("DroidBridgeUSB", "Reliable USB stopped: retransmittedRecords=$retries, reason=$reason")
                    // A watchdog can fire while rawInput is blocked. Propagate closure without
                    // depending on that reader waking up; recovery fences any late callback.
                    bridgeOwner.get()?.transportFailed(reason) ?: onClosed(reason)
                }, onRetransmission = { retries ->
                    Log.i("DroidBridgeUSB", "Reliable USB retransmission: totalRecords=$retries")
                })
            reliable = channel
            // Each replacement starts with sessionReady=false and requires a fresh host RESET.
            val bridge = AoaAccessoryBridge(channel.input, channel.output, closeTransport = {
                channel.close()
            }, onReadFailure = { failure ->
                Log.w("DroidBridgeUSB", "USB frame reader stopped: completedFrames=${failure.completedFrames}, " +
                    "completedBytes=${failure.completedBytes}, lastType=${failure.lastType}, " +
                    "lastPayloadBytes=${failure.lastPayloadBytes}")
                Log.w("DroidBridgeUSB", "USB descriptor read history: ${rawInput.snapshot()}")
            }, onStreamIdle = { state ->
                Log.i("DroidBridgeUSB", "Large stream idle: id=${state.id} tx=${state.sentBytes} " +
                    "rx=${state.receivedBytes} txCredit=${state.sendCredit} rxCredit=${state.receiveCredit} " +
                    "pendingWrites=${state.pendingWrites} queuedFrames=${state.outgoingFrames}")
            }, onClosed = onClosed, relayAcceptor = relayAcceptor, onSessionActive = owned::setSessionActive)
            bridgeOwner.set(bridge)
            return object : UsbAccessoryRecovery.Session {
                override fun start() {
                    bridge.start()
                    Log.i("DroidBridgeUSB", "Accessory session started; bounded startup CPU lease held")
                }
                override fun close() = bridge.close()
            }
        } catch (error: Exception) {
            reliable?.close()
            runCatching { resources?.close() ?: descriptor.close() }
            throw error
        }
    }
}
