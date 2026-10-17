package io.droidbridge.usb

import java.io.IOException
import kotlin.test.*

class ReliableUsbRecordTest {
    @Test fun fragmentedLargeRecordsHaveLinearAllocationAndOwnTheirPayload() {
        val bean = java.lang.management.ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        org.junit.Assume.assumeTrue(bean?.isThreadAllocatedMemorySupported == true)
        bean!! .isThreadAllocatedMemoryEnabled = true
        val payload = ByteArray(16384) { (it * 17).toByte() }
        val record = ReliableUsbRecord(3, ByteArray(16), 1, payload = payload).encode()
        val fragments = record.asList().chunked(512).map { it.toByteArray() }
        repeat(10) { val d = ReliableUsbDecoder(); fragments.forEach(d::append) }
        val d = ReliableUsbDecoder()
        val before = bean.getThreadAllocatedBytes(Thread.currentThread().id)
        var first: ReliableUsbRecord? = null
        repeat(256) {
            for (fragment in fragments) for (decoded in d.append(fragment)) {
                if (first == null) first = decoded
                assertContentEquals(payload, decoded.payload)
            }
        }
        val allocated = bean.getThreadAllocatedBytes(Thread.currentThread().id) - before
        println("fragmented 4MiB allocation bytes=$allocated")
        assertTrue(allocated < 32L * 1024 * 1024, "Decoder allocates superlinear pending-buffer copies: $allocated")
        assertContentEquals(payload, first!!.payload)
    }
    @Test fun rangedDecodeIgnoresOutsideBytesAndDoesNotAliasTheReadBuffer() {
        val encoded=ReliableUsbRecord(3,ByteArray(16),1,payload=byteArrayOf(4,5,6)).encode()
        val source=ByteArray(encoded.size+10) { 99 }.also { encoded.copyInto(it,5) }
        val record=ReliableUsbDecoder().append(source,5,encoded.size).single()
        source.fill(0)
        assertContentEquals(byteArrayOf(4,5,6),record.payload)
        assertFailsWith<IOException> { ReliableUsbDecoder().append(source,-1,1) }
        assertFailsWith<IOException> { ReliableUsbDecoder().append(source,1,source.size) }
    }
    private val epoch = ByteArray(16) { it.toByte() }
    @Test fun independentWireVectorMatchesSwift() {
        val literal = "444252334c494e4b0300000000000003000102030405060708090a0b0c0d0e0f00000001000000020000000100000001039058c6f2c0cb492c533b0a4d14ef77c9d50a3983ff2db1dc4ccf5db61492fa010203"
        val encoded = ReliableUsbRecord(3,epoch,0x100000002,0x100000001,byteArrayOf(1,2,3)).encode()
        assertEquals(literal, encoded.joinToString("") { "%02x".format(it) })
    }
    @Test fun lostPrefixCannotCorruptTheNextDeliveredRecord() {
        val damaged = ReliableUsbRecord(3, epoch, 1, 0, ByteArray(16384) { 42 }).encode()
        val next = ReliableUsbRecord(3, epoch, 2, 0, byteArrayOf(9,8,7)).encode()
        for (lost in listOf(512, 1024, 16384)) {
            val decoder = ReliableUsbDecoder()
            val recovered = decoder.append(damaged.copyOfRange(lost, damaged.size) + next)
            assertEquals(listOf(2L), recovered.map { it.sequence })
            assertContentEquals(byteArrayOf(9,8,7), recovered.single().payload)
        }
    }
    @Test fun corruptBodyWithEmbeddedMagicIsNeverDelivered() {
        val body = "payloadDBR3LINKpayload".toByteArray()
        val first = ReliableUsbRecord(3, epoch, 1, 0, body).encode().apply { this[lastIndex] = 0 }
        val last = ReliableUsbRecord(4, epoch, 0, 7).encode()
        val decoder = ReliableUsbDecoder()
        assertEquals(listOf(7L), decoder.append(first + last).map { it.ack })
    }
    @Test fun everySplitRetainsOnlyWholeVerifiedRecords() {
        val encoded = ReliableUsbRecord(3, epoch, 5, 4, byteArrayOf(1,2,3)).encode()
        for (split in 0..encoded.size) {
            val decoder = ReliableUsbDecoder()
            val result = decoder.append(encoded.copyOfRange(0,split)) + decoder.append(encoded.copyOfRange(split,encoded.size))
            assertEquals(1, result.size)
            assertEquals(5L, result.single().sequence)
            assertContentEquals(byteArrayOf(1,2,3), result.single().payload)
        }
    }
    @Test fun malformedLengthsAndGarbageDoNotHideTheNextValidRecord() {
        val valid = ReliableUsbRecord(1, epoch).encode()
        val bad = valid.copyOf().apply { this[12] = 0x7f }
        val decoder = ReliableUsbDecoder()
        repeat(100) { assertTrue(decoder.append(ByteArray(16384) { 0x55 }).isEmpty()) }
        assertEquals(1, decoder.append(bad + valid).single().kind)
        val small = ReliableUsbRecord(3,epoch,1,payload=byteArrayOf(42)).encode()
        val inRange = small.copyOf().apply { this[14]=0x40; this[15]=0 }
        assertEquals(1L,decoder.append(inRange+small).single().sequence)
        assertFailsWith<IOException> { ReliableUsbRecord(3,epoch,0,0,byteArrayOf(1)).encode() }
        assertFailsWith<IOException> { ReliableUsbRecord(4,epoch,0,-1).encode() }
    }
}
