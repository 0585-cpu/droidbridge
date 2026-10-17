package io.droidbridge.usb

import android.os.ParcelFileDescriptor
import android.os.PowerManager
import java.io.Closeable

/** Owns the descriptor; only an active host session holds an unbounded CPU lease. */
class UsbSessionResources(
    val descriptor: ParcelFileDescriptor,
    powerManager: PowerManager,
) : Closeable {
    private val wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DroidBridge:UsbRelay")
    private var closed = false

    init {
        try {
            wakeLock.setReferenceCounted(false)
            // Allow the first host handshake to arrive with the screen off. A merely attached,
            // unused accessory must not prevent deep sleep forever. Recovery has its own lease.
            wakeLock.acquire(10_000)
        } catch (error: Exception) {
            runCatching { descriptor.close() }
            throw error
        }
    }

    @Synchronized fun setSessionActive(active: Boolean) {
        if (closed) return
        if (active) {
            // Clear the timed bootstrap lease before taking ownership for the live session.
            if (wakeLock.isHeld) wakeLock.release()
            wakeLock.acquire()
        } else if (wakeLock.isHeld) wakeLock.release()
    }

    @Synchronized override fun close() {
        if (closed) return
        closed = true
        try { descriptor.close() }
        finally { if (wakeLock.isHeld) wakeLock.release() }
    }
}
