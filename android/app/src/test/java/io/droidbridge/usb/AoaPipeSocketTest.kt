package io.droidbridge.usb

import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.*

class AoaPipeSocketTest {
    private val frames = LinkedBlockingQueue<AoaFrame>()
    private var closedBy: AoaPipeSocket? = null
    private val pipe = AoaPipeSocket(7, { frames.add(AoaFrame.read(ByteArrayInputStream(it))!!) }) { closedBy = it }

    private fun next() = assertNotNull(frames.poll(2, TimeUnit.SECONDS))
    private fun <T> blocked(body: () -> T): Pair<CountDownLatch, AtomicReference<Result<T>>> {
        val done = CountDownLatch(1); val result = AtomicReference<Result<T>>()
        thread(isDaemon = true) { result.set(runCatching(body)); done.countDown() }
        return done to result
    }

    @Test fun readsHonourSoTimeoutAndPeerFinIsEof() {
        pipe.soTimeout = 50
        assertFailsWith<SocketTimeoutException> { pipe.getInputStream().read(ByteArray(4)) }
        assertTrue(pipe.deliver(byteArrayOf(1, 2, 3)))
        assertFalse(pipe.remoteFinished())
        val buffer = ByteArray(8)
        assertEquals(3, pipe.getInputStream().read(buffer))
        assertEquals(-1, pipe.getInputStream().read(buffer), "FIN after drained data is EOF")
    }

    @Test fun readsReturnCreditOnlyPerHalfWindow() {
        pipe.deliver(ByteArray(20000)); pipe.deliver(ByteArray(20000))
        pipe.getInputStream().read(ByteArray(30000)) // below half a window: no WINDOW per read
        assertNull(frames.poll(100, TimeUnit.MILLISECONDS))
        pipe.getInputStream().read(ByteArray(30000)) // 40000 consumed crosses 32 KiB
        val window = next()
        assertEquals(AoaFrame.WINDOW, window.type)
        assertEquals(40000L, window.credit())
        assertNull(frames.poll(100, TimeUnit.MILLISECONDS))
    }

    @Test fun dataFramesEncodeFromTheCallersBufferUnchanged() {
        val body = ByteArray(1000) { (it * 7).toByte() }
        pipe.getOutputStream().write(body, 100, 500)
        val data = next()
        assertEquals(AoaFrame.DATA, data.type); assertEquals(7, data.streamId)
        assertContentEquals(body.copyOfRange(100, 600), data.payload)
    }

    @Test fun writesWaitForPeerCreditAndRespectThePayloadBudget() {
        val body = ByteArray(AoaFrame.INITIAL_CREDIT + 10) { it.toByte() }
        val (done, result) = blocked { pipe.getOutputStream().write(body) }
        var sent = 0
        while (sent < AoaFrame.INITIAL_CREDIT) {
            val data = next(); assertEquals(AoaFrame.DATA, data.type)
            assertTrue(data.payload.size <= AoaFrame.SEND_PAYLOAD); sent += data.payload.size
        }
        assertEquals(AoaFrame.INITIAL_CREDIT, sent, "never beyond the credit window")
        assertFalse(done.await(150, TimeUnit.MILLISECONDS), "writer waits like a full send buffer")
        pipe.credit(10)
        assertEquals(10, next().payload.size)
        assertTrue(done.await(2, TimeUnit.SECONDS)); result.get().getOrThrow()
        assertFailsWith<IOException> { pipe.credit(AoaFrame.INITIAL_CREDIT + 11L) }
    }

    @Test fun closeFailsBlockedReadsAndWritesAndSendsFinOnce() {
        val (readDone, readResult) = blocked { pipe.getInputStream().read(ByteArray(4)) }
        repeat(4) { pipe.getOutputStream().write(ByteArray(AoaFrame.SEND_PAYLOAD)) }
        val (writeDone, writeResult) = blocked { pipe.getOutputStream().write(ByteArray(AoaFrame.SEND_PAYLOAD)) }
        assertFalse(readDone.await(100, TimeUnit.MILLISECONDS))
        pipe.close(); pipe.close()
        assertTrue(readDone.await(2, TimeUnit.SECONDS) && writeDone.await(2, TimeUnit.SECONDS))
        assertTrue(readResult.get().exceptionOrNull() is IOException)
        assertTrue(writeResult.get().exceptionOrNull() is IOException)
        val types = generateSequence { frames.poll(100, TimeUnit.MILLISECONDS) }.map { it.type }.toList()
        assertEquals(1, types.count { it == AoaFrame.FIN })
        assertSame(pipe, closedBy)
        assertFalse(pipe.deliver(byteArrayOf(1)), "data after close is refused like a closed socket")
        assertTrue(pipe.remoteFinished(), "peer FIN after relay close finishes the stream")
    }

    @Test fun peerAbortFailsBlockedReaderAndWindowOverflowIsAProtocolError() {
        val (done, result) = blocked { pipe.getInputStream().read(ByteArray(4)) }
        pipe.abort()
        assertTrue(done.await(2, TimeUnit.SECONDS)); assertTrue(result.get().exceptionOrNull() is IOException)
        val fresh = AoaPipeSocket(9, {}) {}
        fresh.deliver(ByteArray(AoaFrame.INITIAL_CREDIT))
        assertFailsWith<IOException> { fresh.deliver(byteArrayOf(1)) }
    }

    @Test fun interruptionCancelsABlockedRead() {
        val done = CountDownLatch(1); val result = AtomicReference<Result<Int>>()
        val reader = thread(isDaemon = true) { result.set(runCatching { pipe.getInputStream().read(ByteArray(4)) }); done.countDown() }
        Thread.sleep(50)
        reader.interrupt()
        assertTrue(done.await(2, TimeUnit.SECONDS))
        assertTrue(result.get().exceptionOrNull() is InterruptedException, "runInterruptible relies on this")
    }

    @Test fun aResetFencesLateFramesOfTheOldSessionsRelayStreams() {
        java.net.ServerSocket(0).use { usb -> java.net.Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            val accessory = usb.accept()
            val accepted = LinkedBlockingQueue<java.net.Socket>()
            val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                closeTransport = { accessory.close() }, relayAcceptor = { accepted.add(it) })
            bridge.start()
            val input = java.io.BufferedInputStream(host.getInputStream())
            fun send(f: AoaFrame) = host.getOutputStream().write(f.encode())
            try {
                send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)))
                assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY))
                assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                val old = assertNotNull(accepted.poll(2, TimeUnit.SECONDS))
                send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16) { 1 })) // new host session
                assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                assertFailsWith<IOException> { old.getOutputStream().write(byteArrayOf(1, 2, 3)) }
                send(AoaFrame(AoaFrame.PING, 0))
                assertEquals(AoaFrame.PONG, AoaFrame.read(input)!!.type, "no frame of the old stream follows RESET_OK")
            } finally { bridge.close() }
        } }
    }

    @Test fun lateFramesOfAFinishedInMemoryStreamAreIgnoredWithoutEndingTheSession() {
        java.net.ServerSocket(0).use { usb -> java.net.Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            val accessory = usb.accept()
            val accepted = LinkedBlockingQueue<java.net.Socket>()
            val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                closeTransport = { accessory.close() }, relayAcceptor = { accepted.add(it) })
            bridge.start()
            val input = java.io.BufferedInputStream(host.getInputStream())
            fun send(f: AoaFrame) = host.getOutputStream().write(f.encode())
            fun nextOf(type: Int): AoaFrame { while (true) { val f = AoaFrame.read(input)!!; if (f.type == type) return f } }
            try {
                send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16))); nextOf(AoaFrame.RESET_OK)
                send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY)); nextOf(AoaFrame.OPEN_OK)
                val relay = assertNotNull(accepted.poll(2, TimeUnit.SECONDS))
                send(AoaFrame(AoaFrame.DATA, 1, payload = byteArrayOf(5)))
                assertEquals(5, relay.getInputStream().read())
                relay.close(); nextOf(AoaFrame.FIN)
                send(AoaFrame(AoaFrame.FIN, 1)) // both directions finished: the stream is retired
                send(AoaFrame.window(1, 0)); send(AoaFrame(AoaFrame.CLOSE, 1)) // late frames
                send(AoaFrame(AoaFrame.PING, 0))
                nextOf(AoaFrame.PONG)
                send(AoaFrame(AoaFrame.OPEN, 3, AoaFrame.RELAY))
                assertEquals(AoaFrame.OPEN_OK, nextOf(AoaFrame.OPEN_OK).type, "the session still serves new streams")
            } finally { bridge.close() }
        } }
    }
}
