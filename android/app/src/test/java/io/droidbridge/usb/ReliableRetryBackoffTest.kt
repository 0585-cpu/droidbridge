package io.droidbridge.usb

import java.io.IOException
import kotlin.test.*

class ReliableRetryBackoffTest {
    private val epoch = ByteArray(16) { it.toByte() }

    private fun ready(host: Boolean = true): ReliableUsbState = ReliableUsbState(if (host) epoch else null, 0).also {
        it.receive(ReliableUsbRecord(if (host) 2 else 1, epoch), 0)
        if (!host) assertEquals(2, it.next(0)!!.kind)
    }

    @Test fun stalledFullWindowBoundsRetriesInBothDirectionsWithoutExtendingDeadline() {
        val counts = ArrayList<Pair<Long, Int>>()
        for (host in listOf(true, false)) {
            val state = ready(host)
            repeat(32) { assertTrue(state.offer(ByteArray(16384) { 7 }, 0)) }
            assertFalse(state.offer(byteArrayOf(1), 0))
            var sends = 0
            for (time in 0L..9500L step 500L) {
                while (state.next(time) != null) sends++
            }
            println("stalled_window host=$host durationMs=10000 sends=$sends retries=${state.retransmissions}")
            counts += state.retransmissions to sends
            assertEquals(ReliableUsbState.NO_PROGRESS_MS, state.deadlineAt())
            assertNull(state.next(10_000), "a ~45 s freeze must not end the session at 10 s")
            assertFailsWith<IOException> { state.next(ReliableUsbState.NO_PROGRESS_MS) }
        }
        assertEquals(listOf(192L to 224, 192L to 224), counts,
            "Stalled records must back off instead of resending the full window every 500 ms")
    }

    @Test fun retryIntervalsGrowAndWriterWakeMatchesTheActualNextSend() {
        val state = ready()
        state.offer(byteArrayOf(1), 0)
        for ((time, next) in listOf(0L to 500L, 500L to 1500L, 1500L to 3500L, 3500L to 5500L)) {
            assertEquals(1L, state.next(time)!!.sequence)
            assertEquals(next, state.nextWakeAt(time))
            assertNull(state.next(next - 1), "No busy retry before $next")
        }
    }

    @Test fun realAckProgressResetsFutureIntervalsWithoutRetriggeringOldRecords() {
        val state = ready()
        repeat(2) { state.offer(byteArrayOf(it.toByte()), 0) }
        for (time in listOf(0L, 500L, 1500L)) repeat(2) { state.next(time)!! }
        state.receive(ReliableUsbRecord(4, epoch, ack = 1), 1600)
        assertNull(state.next(1600), "ACK progress must not make the remaining window immediately due")
        state.offer(byteArrayOf(3), 1700)
        assertEquals(3L, state.next(1700)!!.sequence)
        assertEquals(2200L, state.nextWakeAt(1700), "New records retain their own first retry")
        assertEquals(3L, state.next(2200)!!.sequence)
        assertEquals(3L, state.next(3200)!!.sequence)
        assertEquals(2L, state.next(3500)!!.sequence)
        assertEquals(4000L, state.nextWakeAt(3500), "Real progress resets the interval after the scheduled retry")
        assertEquals(2L, state.next(4000)!!.sequence)
        state.receive(ReliableUsbRecord(4, epoch, ack = 1), 4050)
        assertNull(state.next(4500), "A duplicate ACK must not reset retry backoff")
        assertEquals(2L, state.next(5000)!!.sequence)
        assertEquals(3L, state.next(5200)!!.sequence)
        assertNull(state.next(6000), "Duplicate ACKs must not shorten future intervals either")
        assertEquals(1_600L+ReliableUsbState.NO_PROGRESS_MS, state.deadlineAt(), "Neither duplicate ACKs nor new pending data extend the progress deadline")
        assertFailsWith<IOException> { state.checkDeadline(1_600L+ReliableUsbState.NO_PROGRESS_MS) }
    }

    @Test fun backoffDoesNotDelayAckDeadlineAndPiggybacksOnDueData() {
        val state = ready()
        state.offer(byteArrayOf(42), 0)
        for (time in listOf(0L, 500L, 1500L)) state.next(time)
        state.receive(ReliableUsbRecord(3, epoch, sequence = 1, payload = byteArrayOf(7)), 1600)
        assertEquals(1602L, state.nextWakeAt(1600))
        assertNull(state.next(1600))
        val ack = state.next(1602)!!
        assertEquals(4, ack.kind)
        assertEquals(1L, ack.ack)
        assertEquals(3500L, state.nextWakeAt(1600))
        state.receive(ReliableUsbRecord(3, epoch, sequence = 2, payload = byteArrayOf(8)), 3500)
        val data = state.next(3500)!!
        assertEquals(3, data.kind)
        assertEquals(2L, data.ack)
    }

    @Test fun corruptDataAndLostAckRecoverExactlyOnceAfterBackoff() {
        val sender = ready()
        val receiver = ready(false)
        val decoder = ReliableUsbDecoder()
        sender.offer(byteArrayOf(4, 5, 6), 0)
        val corrupt = sender.next(0)!!.encode().also { it[it.lastIndex] = 99 }
        assertTrue(decoder.append(corrupt).isEmpty(), "Integrity checks must reject damaged data")
        val retry = decoder.append(sender.next(500)!!.encode()).single()
        assertContentEquals(byteArrayOf(4, 5, 6), receiver.receive(retry, 500))
        assertNotNull(receiver.next(502)) // Lose its delayed cumulative ACK.
        assertNull(sender.next(1000))
        val duplicate = decoder.append(sender.next(1500)!!.encode()).single()
        assertNull(receiver.receive(duplicate, 1500), "Lost ACKs cannot redeliver payload")
        sender.receive(receiver.next(1500)!!, 1500)
        assertNull(sender.nextWakeAt(1500))
        assertNull(sender.deadlineAt())
    }

    @Test fun pausedReceiverDrainsAFullWindowInOrderOnResume() {
        val sender = ready()
        val receiver = ready(false)
        repeat(32) { sender.offer(byteArrayOf(it.toByte()), 0) }
        for (time in listOf(0L, 500L, 1500L)) {
            repeat(32) { assertNull(receiver.receive(sender.next(time)!!, time, acceptPayload = false)) }
            sender.receive(receiver.next(time)!!, time) // Duplicate ACK zero must not reset the sender.
        }
        assertNull(sender.next(2000), "Paused receiver must not trigger a full-window retry every 500 ms")
        val output = ArrayList<Byte>()
        repeat(32) {
            output += receiver.receive(sender.next(3500)!!, 3500)!!.toList()
            receiver.next(3500)?.let { ack -> sender.receive(ack, 3500) }
        }
        assertContentEquals(ByteArray(32) { it.toByte() }, output.toByteArray())
        assertNull(sender.nextWakeAt(3500))
        assertTrue(sender.offer(byteArrayOf(32), 3501))
        assertContentEquals(byteArrayOf(32), receiver.receive(sender.next(3501)!!, 3501))
    }
}
