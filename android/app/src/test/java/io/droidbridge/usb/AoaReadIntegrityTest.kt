package io.droidbridge.usb

import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AoaReadIntegrityTest {
    private val ping = byteArrayOf(0x44, 0x42, 0x41, 0x4d, 2, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    private val dataHeader = byteArrayOf(0x44, 0x42, 0x41, 0x4d, 2, 3, 0, 0, 0, 0, 0, 1, 0, 0, 0x40, 0)

    @Test fun malformedFrameReportsTheLastValidatedBoundaryAndStillCloses() {
        val invalid = ping.copyOf().apply { this[0] = 0 }
        val bytes = ping + dataHeader + ByteArray(16384) { 0x61 } + invalid
        val failure = AtomicReference<AoaAccessoryBridge.ReadFailure?>()
        val reason = AtomicReference<String>()
        val closed = CountDownLatch(1)
        val bridge = AoaAccessoryBridge(ByteArrayInputStream(bytes), ByteArrayOutputStream(),
            closeTransport = {}, onReadFailure = { failure.set(it) }, onClosed = {
                reason.set(it)
                closed.countDown()
            })
        try {
            bridge.start()
            assertTrue(closed.await(5, TimeUnit.SECONDS), "Malformed USB input must close the session")
            assertEquals("invalid AOA magic", reason.get())
            // No payload or malformed header content belongs in this failure record.
            assertEquals(AoaAccessoryBridge.ReadFailure(2, 16416, 3, 16384), failure.get())
        } finally { bridge.close() }
    }

    @Test fun reliableChannelFailureStillReportsLastFrameBeforeItsReaderThrows() {
        val owner = AtomicReference<AoaAccessoryBridge>()
        val failure = AtomicReference<AoaAccessoryBridge.ReadFailure?>()
        val closed = CountDownLatch(1)
        val reports = java.util.concurrent.atomic.AtomicInteger()
        val input = object : ByteArrayInputStream(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)).encode()) {
            override fun read(): Int {
                if (available() == 0) {
                    owner.get().transportFailed("raw USB read failed")
                    throw java.io.IOException("raw USB read failed")
                }
                return super.read()
            }
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                if (available() == 0) {
                    owner.get().transportFailed("raw USB read failed")
                    throw java.io.IOException("raw USB read failed")
                }
                return super.read(b, off, len)
            }
        }
        val bridge = AoaAccessoryBridge(input, ByteArrayOutputStream(), closeTransport = {},
            onReadFailure = { reports.incrementAndGet(); failure.set(it) }, onClosed = { closed.countDown() })
        owner.set(bridge)
        try {
            bridge.start()
            assertTrue(closed.await(3, TimeUnit.SECONDS))
            assertEquals(AoaAccessoryBridge.ReadFailure(1, 32, AoaFrame.RESET, 16), failure.get())
            assertEquals(1, reports.get())
        } finally { bridge.close() }
    }

    @Test fun bufferedFrameReadsNeverTruncateAnAccessoryRequest() {
        val payload = ByteArray(16384) { (it * 31).toByte() }
        val frames = ping + dataHeader + payload + ping
        // The first DATA crosses one 16-KiB request and its remaining bytes share
        // the next request with another frame. Unread request tails are discarded,
        // matching UsbManager.openAccessory's documented descriptor contract.
        val transfers = listOf(frames.copyOfRange(0, 16384), frames.copyOfRange(16384, frames.size))
        val source = AccessoryRequests(transfers)
        val input = BufferedInputStream(source, AoaFrame.MAX_PAYLOAD)
        assertEquals(AoaFrame.PING, AoaFrame.read(input)!!.type)
        assertContentEquals(payload, AoaFrame.read(input)!!.payload)
        assertEquals(AoaFrame.PING, AoaFrame.read(input)!!.type)
        assertNull(AoaFrame.read(input))
        assertEquals(0, source.discardedBytes, "Every USB request must fit its descriptor read")
    }

    private class AccessoryRequests(private val transfers: List<ByteArray>) : InputStream() {
        private var next = 0
        var discardedBytes = 0
            private set

        override fun read(): Int {
            val byte = ByteArray(1)
            return if (read(byte, 0, 1) < 0) -1 else byte[0].toInt() and 255
        }

        override fun read(bytes: ByteArray, offset: Int, length: Int): Int {
            if (length == 0) return 0
            if (next == transfers.size) return -1
            val request = transfers[next++]
            val copied = minOf(length, request.size)
            request.copyInto(bytes, offset, 0, copied)
            discardedBytes += request.size - copied
            return copied
        }
    }
}
