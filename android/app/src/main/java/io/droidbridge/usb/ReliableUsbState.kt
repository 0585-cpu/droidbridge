package io.droidbridge.usb

import java.io.IOException

/** Access is serialized by the channel monitor. Never performs IO or callbacks. */
internal class ReliableUsbState(private var epoch: ByteArray?, private val started: Long) {
    private data class Pending(val sequence: Long, val payload: ByteArray,
                               var retryAt: Long? = null, var retryDelay: Long = 500)
    private val host = epoch != null
    private var ready = false
    private var helloSent: Long? = null
    private var helloReply = false
    private var ackAt: Long? = null
    private var ackRecords = 0
    private var sent = 0L
    private var emitted = 0L
    private var acknowledged = 0L
    private var received = 0L
    private var progress = started
    private val pending = ArrayList<Pending>()
    var retransmissions = 0L
        private set

    fun offer(bytes: ByteArray, now: Long): Boolean = offer(bytes, 0, bytes.size, now)

    fun offer(bytes: ByteArray, offset: Int, length: Int, now: Long): Boolean {
        if (offset < 0 || length !in 1..ReliableUsbRecord.MAX_PAYLOAD || offset > bytes.size-length)
            throw IOException("invalid reliable USB payload")
        if (!ready || pending.size >= 32) return false
        if (sent == Long.MAX_VALUE) throw IOException("USB sequence exhausted")
        if (pending.isEmpty()) progress = now
        sent++
        pending += Pending(sent, bytes.copyOfRange(offset,offset+length))
        return true
    }

    fun receive(record: ReliableUsbRecord, now: Long, acceptPayload: Boolean = true): ByteArray? {
        if (!host && record.kind == 1) {
            if (epoch != null && !record.epoch.contentEquals(epoch)) {
                // Fence the old writer before acknowledging a different host session.
                throw IOException("USB host session changed; reopen accessory")
            }
            epoch = record.epoch.copyOf(); ready = true; helloReply = true
            return null
        }
        if (!record.epoch.contentEquals(epoch)) return null
        if (host && record.kind == 2) { ready = true; return null }
        if (!ready || record.kind !in 3..4) return null
        if (record.ack > emitted) throw IOException("USB ACK exceeds transmitted data")
        if (record.ack > acknowledged) {
            acknowledged = record.ack; pending.removeAll { it.sequence <= acknowledged }; progress = now
            // Real progress resets future intervals, not already scheduled retries. Retiming the
            // whole window here would turn a delayed ACK burst into another bulk resend burst.
            pending.forEach { it.retryDelay = 500 }
        }
        if (record.kind != 3) return null
        // Always consume the opposite direction's ACK, even when local delivery is paused.
        // Refused DATA is not acknowledged; the existing retry protocol retains ownership.
        if (!acceptPayload || received == Long.MAX_VALUE || record.sequence != received + 1) {
            ackAt = now // Immediately expose gaps, duplicates and receive backpressure.
            return null
        }
        received = record.sequence
        ackRecords++
        if (ackAt == null) ackAt = now + 2
        if (ackRecords >= 8) ackAt = now
        return record.payload
    }

    /** Only the dedicated writer calls next; receive never waits for a bulk write. */
    fun next(now: Long): ReliableUsbRecord? {
        checkDeadline(now)
        if (host && !ready) {
            if (helloSent == null || now-helloSent!! >= 500) {
                helloSent = now; return ReliableUsbRecord(1,epoch!!)
            }
            return null
        }
        val current = epoch ?: return null
        if (!ready) return null
        if (helloReply) { helloReply = false; return ReliableUsbRecord(2,current) }
        val packet = pending.firstOrNull { it.retryAt == null || now >= it.retryAt!! }
        if (packet != null) {
            if (packet.retryAt != null) retransmissions++
            packet.retryAt = now + packet.retryDelay
            packet.retryDelay = minOf(packet.retryDelay * 2, 2000)
            emitted = maxOf(emitted,packet.sequence)
            ackAt = null; ackRecords = 0 // Piggyback ACK cancels its standalone deadline.
            return ReliableUsbRecord(3,current,packet.sequence,received,packet.payload)
        }
        if (ackAt?.let { now >= it } == true) {
            ackAt = null; ackRecords = 0
            return ReliableUsbRecord(4,current,ack=received)
        }
        return null
    }

    /** Absolute monotonic times let the channel sleep until work is actually due. */
    fun nextWakeAt(now: Long): Long? {
        if (host && !ready) return helloSent?.plus(500) ?: now
        if (!ready) return null
        if (helloReply) return now
        val retry = pending.minOfOrNull { it.retryAt ?: now }
        return when { retry == null -> ackAt; ackAt == null -> retry; else -> minOf(retry,ackAt!!) }
    }

    fun deadlineAt(): Long? = when {
        host && !ready -> started + 10_000
        pending.isNotEmpty() -> progress + NO_PROGRESS_MS
        else -> null
    }

    fun checkDeadline(now: Long) {
        // The phone may be attached well before the user presses Connect on the Mac.
        // Detach/stop still closes the owned descriptor; only an initiating host times out.
        if (host && !ready && now-started >= 10_000) throw IOException("Reliable USB handshake timed out; reconnect from both DroidBridge apps")
        if (pending.isNotEmpty() && now-progress >= NO_PROGRESS_MS) throw IOException("Reliable USB delivery made no progress for ${NO_PROGRESS_MS/1000} seconds")
    }

    companion object {
        // Samsung's freezer can stop the app for tens of seconds (seen: ~45 s) while USB stays
        // attached. Shorter deadlines turn that pause into a torn-down session and dropped flows.
        const val NO_PROGRESS_MS = 60_000L
    }
}
