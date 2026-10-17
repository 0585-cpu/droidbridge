package io.droidbridge.usb

/** Selector-owned cumulative WINDOW scheduling. */
internal class AoaWindowUpdate {
    private var advertised = 0L
    var deadlineNanos: Long? = null
        private set
    fun consumed(total: Long, now: Long): Boolean {
        if (total <= advertised) return false
        if (deadlineNanos == null) deadlineNanos = now + 5_000_000
        return total - advertised >= 32768 || isDue(now)
    }
    fun isDue(now: Long): Boolean = deadlineNanos?.let { now >= it } == true
    fun sent(total: Long) {
        advertised = total
        deadlineNanos = null
    }
}
