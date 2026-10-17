package io.droidbridge.usb

import java.io.IOException
import kotlin.test.*

class ReliableUsbStateTest {
    @Test fun offeredSliceRetainsOwnershipAcrossCallerReuseAndRetries() {
        val epoch=ByteArray(16)
        val state=ReliableUsbState(epoch,0)
        state.receive(ReliableUsbRecord(2,epoch),0)
        val source=byteArrayOf(99,4,5,6,99)
        assertTrue(state.offer(source,1,3,0))
        source.fill(0)
        assertContentEquals(byteArrayOf(4,5,6),state.next(0)!!.payload)
        assertContentEquals(byteArrayOf(4,5,6),state.next(500)!!.payload)
    }
    @Test fun idleHasNoTimersAndOutstandingRecordsKeepRetryAndFailureDeadlines() {
        val epoch=ByteArray(16)
        val phone=ReliableUsbState(null,0)
        assertNull(phone.nextWakeAt(50)); assertNull(phone.deadlineAt())
        phone.receive(ReliableUsbRecord(1,epoch),100)
        assertEquals(100L,phone.nextWakeAt(100))
        phone.next(100)
        assertNull(phone.nextWakeAt(100)); assertNull(phone.deadlineAt())
        phone.offer(byteArrayOf(1),200)
        assertEquals(200L+ReliableUsbState.NO_PROGRESS_MS,phone.deadlineAt())
        phone.next(200)
        assertEquals(700L,phone.nextWakeAt(300))
        phone.receive(ReliableUsbRecord(4,epoch,ack=1),400)
        assertNull(phone.nextWakeAt(400)); assertNull(phone.deadlineAt())
        val host=ReliableUsbState(epoch,0)
        assertEquals(10000L,host.deadlineAt())
        host.next(0)
        assertEquals(500L,host.nextWakeAt(20))
    }
    private val epoch = ByteArray(16) { it.toByte() }
    @Test fun phoneStillAcceptsFirstHostAfterFiveMinutesWaiting() {
        val phone = ReliableUsbState(null, 0)
        phone.checkDeadline(300_000)
        assertNull(phone.next(300_000))
        assertFalse(phone.offer(byteArrayOf(7), 300_000))
        phone.receive(ReliableUsbRecord(1, epoch), 300_001)
        assertEquals(2, phone.next(300_001)!!.kind)
        assertContentEquals(byteArrayOf(42), phone.receive(ReliableUsbRecord(3, epoch, 1, payload=byteArrayOf(42)), 300_002))
        assertTrue(phone.offer(byteArrayOf(8), 300_003))
        phone.next(300_003)
        assertFailsWith<IOException> { phone.checkDeadline(300_003+ReliableUsbState.NO_PROGRESS_MS) }
    }
    @Test fun waitingForPairingApprovalAfterHelloDoesNotExpireTransport() {
        val phone = ReliableUsbState(null, 0)
        phone.receive(ReliableUsbRecord(1, epoch), 9_999)
        phone.checkDeadline(120_000)
        assertEquals(2, phone.next(120_000)!!.kind)
    }
    @Test fun pendingDataCarriesAckWithoutBeingStarvedByReceiveTraffic() {
        val state = ReliableUsbState(epoch,0)
        state.receive(ReliableUsbRecord(2,epoch),0)
        state.offer(byteArrayOf(42),0)
        state.receive(ReliableUsbRecord(3,epoch,1,payload=byteArrayOf(7)),0)
        val packet = state.next(0)!!
        assertEquals(3,packet.kind)
        assertEquals(1L,packet.ack)
    }
    @Test fun lossesReorderingAndDuplicateAcksPreserveBytesAndBoundTheWindow() {
        val host = ReliableUsbState(epoch, 0)
        val phone = ReliableUsbState(null, 0)
        phone.receive(host.next(0)!!, 0)
        phone.next(0) // lost HELLO_ACK
        phone.receive(host.next(500)!!, 500)
        host.receive(phone.next(500)!!, 500)
        repeat(32) { assertTrue(host.offer(byteArrayOf(it.toByte()), 1000)) }
        assertFalse(host.offer(byteArrayOf(99), 1000))
        val lost = host.next(1000)!!
        assertNull(phone.receive(host.next(1000)!!, 1000)) // reorder
        host.receive(phone.next(1000)!!, 1000)
        assertFalse(host.offer(byteArrayOf(99), 1000))
        assertContentEquals(byteArrayOf(0), phone.receive(lost, 1000))
        assertNotNull(phone.next(1002)) // lost delayed ACK
        val retry = host.next(1500)!!
        assertEquals(1L, retry.sequence)
        assertNull(phone.receive(retry, 1500))
        host.receive(phone.next(1500)!!, 1500)
        assertTrue(host.offer(byteArrayOf(32), 1500))
        var output = byteArrayOf(0)
        repeat(32) {
            output += phone.receive(host.next(2000)!!, 2000)!!
            phone.next(2000)?.let { ack -> host.receive(ack, 2000) }
        }
        assertContentEquals(ByteArray(33) { it.toByte() }, output)
        assertNull(host.nextWakeAt(2000), "Batched ACKs must drain the whole window")
        assertFailsWith<IOException> { host.receive(ReliableUsbRecord(4,epoch,ack=34),2000) }
        assertNull(phone.receive(ReliableUsbRecord(3,ByteArray(16){8},1,payload=byteArrayOf(88)),2000))
        assertFailsWith<IOException> { phone.receive(ReliableUsbRecord(1,ByteArray(16){8}),2000) }
        host.offer(byteArrayOf(44),3000); host.next(3000)
        host.next(13000) // retransmits instead of failing: a shorter phone freeze keeps the session
        assertFailsWith<IOException> { host.next(3000+ReliableUsbState.NO_PROGRESS_MS) }
        assertFailsWith<IOException> { ReliableUsbState(epoch,0).next(10000) }
    }
}
