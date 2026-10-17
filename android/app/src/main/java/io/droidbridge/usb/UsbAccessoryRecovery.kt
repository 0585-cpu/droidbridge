package io.droidbridge.usb

import java.io.Closeable

/** Owns user intent and fences opens/callbacks; platform USB calls run outside its monitor. */
internal class UsbAccessoryRecovery<K : Any>(
    private val eligible: (K) -> Boolean,
    private val open: (K, (String) -> Unit) -> Session,
    private val schedule: (Long, () -> Unit) -> Closeable,
    private val holdRecovery: (Long) -> Closeable,
    private val nowMillis: () -> Long,
    private val status: (String) -> Unit,
) : Closeable {
    interface Session : Closeable { fun start() }
    private class Attempt<K>(val key: K) {
        var session: Session? = null
        var startedAt: Long? = null
    }
    private class Retry<K>(val key: K) { var task: Closeable? = null }

    private var selected: K? = null
    private var active: Attempt<K>? = null
    private var pending: Retry<K>? = null
    private var recoveryLease: Closeable? = null
    private var recoveryDeadline: Long? = null
    private var retries = 0

    fun connect(key: K) {
        val attempt = synchronized(this) {
            if (key == selected && (active != null || pending != null)) return
            stopLocked()
            selected = key
            Attempt(key).also { active = it }
        }
        openAttempt(attempt, initial = true)
    }

    @Synchronized fun detached(key: K) { if (key == selected) close() }

    @Synchronized override fun close() {
        val wasEnabled = selected != null
        stopLocked()
        if (wasEnabled) status("USB disconnected")
    }

    private fun openAttempt(attempt: Attempt<K>, initial: Boolean) {
        var opened: Session? = null
        try {
            if (!eligible(attempt.key)) {
                synchronized(this) {
                    if (active === attempt) {
                        stopLocked()
                        status("USB unavailable. Reconnect the cable and allow USB access.")
                    }
                }
                if (initial) error("Allow DroidBridge to access the connected USB accessory.")
                return
            }
            synchronized(this) { if (active !== attempt) return }
            opened = open(attempt.key) { reason -> failed(attempt, reason) }
            synchronized(this) {
                if (active !== attempt) {
                    opened.close()
                    return
                }
                // Give Stop ownership as soon as the descriptor returns, even if the final
                // platform permission/presence query is still in progress.
                attempt.session = opened
            }
            // Permission or presence can change while openAccessory is in progress.
            val available = eligible(attempt.key)
            synchronized(this) {
                if (active !== attempt) {
                    opened.close()
                    return
                }
                if (!available || (!initial && nowMillis() >= (recoveryDeadline ?: 0))) {
                    stopLocked()
                    opened.close()
                    status("USB recovery stopped. Reconnect the cable and allow USB access.")
                    return
                }
                attempt.startedAt = nowMillis()
                status("USB accessory connected")
                opened.start()
                // A synchronous failure in start may already have scheduled another retry.
                if (active === attempt) releaseRecoveryLocked()
            }
        } catch (error: Exception) {
            synchronized(this) {
                if (active === attempt) {
                    if (initial) stopLocked()
                    else failed(attempt, error.message ?: "Cannot reopen USB accessory")
                }
            }
            runCatching { opened?.close() }
            if (initial) throw error
        }
    }

    @Synchronized private fun failed(attempt: Attempt<K>, reason: String) {
        if (active !== attempt) return
        active = null
        val now = nowMillis()
        // Merely opening the descriptor is not success: repeated immediate failures share a cap.
        if (attempt.startedAt?.let { now - it >= STABLE_SESSION_MS } == true) {
            retries = 0
            recoveryDeadline = null
        }
        val deadline = recoveryDeadline ?: (now + RECOVERY_WINDOW_MS).also { recoveryDeadline = it }
        val delay = RETRY_DELAYS_MS.getOrNull(retries)
        if (delay == null || now + delay >= deadline) {
            stopLocked()
            status("USB recovery exhausted ($reason). Reconnect USB to try again.")
            return
        }
        try {
            if (recoveryLease == null) recoveryLease = holdRecovery(deadline - now)
            retries++
            val retry = Retry(attempt.key)
            pending = retry
            status("USB interrupted ($reason). Reconnecting ($retries/3)…")
            retry.task = schedule(delay) { retry(retry) }
        } catch (_: Exception) {
            stopLocked()
            status("USB recovery unavailable. Reconnect USB to try again.")
        }
    }

    private fun retry(retry: Retry<K>) {
        val attempt = synchronized(this) {
            if (pending !== retry || selected != retry.key) return
            pending = null
            if (nowMillis() >= (recoveryDeadline ?: 0)) {
                stopLocked()
                status("USB recovery timed out. Reconnect USB to try again.")
                return
            }
            Attempt(retry.key).also { active = it }
        }
        openAttempt(attempt, initial = false)
    }

    /** Call with the monitor held. Invalidate before closing, since close can invoke onClosed. */
    private fun stopLocked() {
        val old = active?.session
        active = null
        selected = null
        pending?.task?.close()
        pending = null
        releaseRecoveryLocked()
        recoveryDeadline = null
        retries = 0
        runCatching { old?.close() }
    }

    private fun releaseRecoveryLocked() {
        recoveryLease?.close()
        recoveryLease = null
    }

    private companion object {
        val RETRY_DELAYS_MS = longArrayOf(1_000, 2_000, 4_000)
        const val RECOVERY_WINDOW_MS = 15_000L
        const val STABLE_SESSION_MS = 30_000L
    }
}
