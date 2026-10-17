package io.droidbridge.usb

import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFailsWith
import kotlin.test.assertSame

class AccessoryReadTraceTest {
    @Test fun ordinaryReadsKeepCountersWithoutFingerprintWork() {
        val trace = AccessoryReadTrace(ByteArrayInputStream(ByteArray(16384)))
        trace.read(ByteArray(16384))
        assertEquals(16384, trace.snapshot().bytesReceived)
        assertNull(trace.snapshot().recent.single().sha256)
        assertNull(trace.snapshot().recent.single().prefix16Sha256)
    }

    @Test fun watchdogSnapshotIsConsistentWhileReaderUpdatesHistory() {
        val raw = AccessoryReadTrace(object : InputStream() {
            override fun read(): Int = 0
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                b.fill(0, off, off + len); return len
            }
        })
        val reader = kotlin.concurrent.thread {
            val bytes = ByteArray(16_384)
            repeat(4000) { raw.read(bytes) }
        }
        try {
            while (reader.isAlive) {
                val snapshot = raw.snapshot()
                if (snapshot.calls > 0) {
                    assertEquals(snapshot.calls, snapshot.recent.last().ordinal)
                    assertEquals(snapshot.bytesReceived, snapshot.recent.last().endOffset)
                    assertEquals(snapshot.calls * 16_384, snapshot.bytesReceived)
                    snapshot.recent.forEach { assertEquals(16_384, it.returned) }
                }
            }
        } finally { reader.join(5000) }
    }

    @Test fun rawRequestHistoryDistinguishesDescriptorReadsFromParserConsumption() {
        val header = byteArrayOf(0x44, 0x42, 0x41, 0x4d, 2, 3, 0, 0, 0, 0, 0, 1, 0, 0, 0x40, 0)
        val payload = ByteArray(16384) { (it * 17).toByte() }
        val ping = byteArrayOf(0x44, 0x42, 0x41, 0x4d, 2, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        for (reportsAvailable in listOf(false, true)) {
            val raw = AccessoryReadTrace(Requests(listOf(header + payload.copyOfRange(0, 16368),
                payload.copyOfRange(16368, 16384), ping), reportsAvailable))
            val buffered = BufferedInputStream(raw, 16384)
            assertContentEquals(payload, AoaFrame.read(buffered)!!.payload)
            assertEquals(AoaFrame.PING, AoaFrame.read(buffered)!!.type)
            assertNull(AoaFrame.read(buffered))
            assertEquals(AccessoryReadTrace.Snapshot(4, 16416, listOf(
                AccessoryReadTrace.Read(1, 16384, 16384, 16384),
                AccessoryReadTrace.Read(2, 16384, 16, 16400),
                AccessoryReadTrace.Read(3, 16384, 16, 16416),
                AccessoryReadTrace.Read(4, 16384, -1, 16416),
            )), raw.snapshot().withoutHashes())
        }
    }

    @Test fun historyIsBoundedWhileTotalsAndReadArgumentsRemainAccurate() {
        val raw = AccessoryReadTrace(ByteArrayInputStream(ByteArray(11) { it.toByte() }))
        val bytes = ByteArray(3) { -1 }
        repeat(10) { assertEquals(1, raw.read(bytes, 1, 1)) }
        assertEquals(10, raw.read())
        assertEquals(-1, raw.read())
        assertEquals(-1, bytes[0].toInt())
        assertEquals(9, bytes[1].toInt())
        assertEquals(-1, bytes[2].toInt())
        val snapshot = raw.snapshot().withoutHashes()
        assertEquals(12L, snapshot.calls)
        assertEquals(11L, snapshot.bytesReceived)
        assertEquals(8, snapshot.recent.size)
        assertEquals(AccessoryReadTrace.Read(5, 1, 1, 5), snapshot.recent.first())
        assertEquals(AccessoryReadTrace.Read(12, 1, -1, 11), snapshot.recent.last())
    }

    @Test fun nativeReadErrorsAreRecordedWithoutRetryOrExceptionReplacement() {
        val failure = IOException("injected descriptor error")
        val raw = AccessoryReadTrace(object : InputStream() {
            override fun read(): Int = throw failure
        })
        assertSame(failure, assertFailsWith<IOException> { raw.read(ByteArray(16384)) })
        assertEquals(AccessoryReadTrace.Snapshot(1, 0,
            listOf(AccessoryReadTrace.Read(1, 16384, -2, 0))), raw.snapshot())
    }

    @Test fun fingerprintsCoverOnlyReturnedBytesAndTheirFirstSixteenBytes() {
        val raw = AccessoryReadTrace(ByteArrayInputStream("abc".toByteArray()), fingerprints = true)
        val target = ByteArray(8) { -1 }
        assertEquals(3, raw.read(target, 2, 5))
        val abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        assertEquals(abc, raw.snapshot().recent.single().sha256)
        assertEquals(abc, raw.snapshot().recent.single().prefix16Sha256)
        assertEquals(-1, raw.read(target))
        assertNull(raw.snapshot().recent.last().sha256)
        assertNull(raw.snapshot().recent.last().prefix16Sha256)

        val header = byteArrayOf(0x44, 0x42, 0x41, 0x4d, 2, 3, 0, 0, 0, 0, 0, 1, 0, 0, 0x40, 0)
        val rawLarge = AccessoryReadTrace(ByteArrayInputStream(header + ByteArray(16368) { 0x5a }), fingerprints = true)
        assertEquals(16384, rawLarge.read(ByteArray(16384)))
        assertEquals("b5260aef3eea57340537b68414adcfccb58ce8d55bb0f84270a0bdb01b0d1a8c",
            rawLarge.snapshot().recent.single().sha256)
        assertEquals("eaf02218215555c609df7966f90b03fcd674fca93acf0777098f77e42b75e8d8",
            rawLarge.snapshot().recent.single().prefix16Sha256)
    }

    @Test fun packetPrefixLossModelFailsAtFreshReadAndMatchesHostSuffixVector() {
        val window = AoaFrame.window(1, 140).encode()
        val data = AoaFrame(AoaFrame.DATA, 1, payload = ByteArray(1196) { 0x5a }).encode()
        val raw = AccessoryReadTrace(Requests(listOf(window, data.copyOfRange(512, data.size)), false), fingerprints = true)
        val input = BufferedInputStream(raw, 16384)
        assertEquals(AoaFrame.WINDOW, AoaFrame.read(input)!!.type)
        assertEquals("invalid AOA magic", assertFailsWith<IOException> { AoaFrame.read(input) }.message)
        val reads = raw.snapshot().recent
        assertEquals(24L, reads[0].endOffset)
        assertEquals(700, reads[1].returned)
        assertEquals(724L, reads[1].endOffset)
        assertEquals("ddc821426ba897f5ea567317276fdd1ceef54c697603e9a5645201d9eda2993b", reads[1].sha256)
        assertEquals("1c712ecc21e27e374111d5a1beeaf75a4e343b3814c1847cba14013420809873", reads[1].prefix16Sha256)
    }

    private fun AccessoryReadTrace.Snapshot.withoutHashes() = copy(
        recent = recent.map { it.copy(sha256 = null, prefix16Sha256 = null) })

    private class Requests(private val requests: List<ByteArray>, private val reportsAvailable: Boolean) : InputStream() {
        private var index = 0
        override fun available() = if (reportsAvailable && index < requests.size) requests[index].size else 0
        override fun read(): Int = error("Only full descriptor reads are expected")
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (index == requests.size) return -1
            val request = requests[index++]
            val count = minOf(length, request.size)
            request.copyInto(bytes, offset, 0, count)
            return count
        }
    }
}
