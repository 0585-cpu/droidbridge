package io.droidbridge.relay

import java.io.ByteArrayOutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import java.io.InputStream
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

@OptIn(ExperimentalCoroutinesApi::class)
class StreamBridgeTest {
    // Android socket reads need the descriptor closed; interrupting their thread is insufficient.
    private class CloseOnlyInput(private val started: CountDownLatch) : InputStream() {
        private val closed = AtomicBoolean()
        private val released = CountDownLatch(1)
        override fun read(): Int {
            started.countDown()
            while (!closed.get()) {
                try { released.await() } catch (_: InterruptedException) { }
            }
            return -1
        }
        override fun read(bytes: ByteArray, offset: Int, length: Int): Int = read()
        override fun close() { closed.set(true); released.countDown() }
    }

    private class Capture(val name: String) {
        val toBridge = PipedOutputStream()
        val bridgeIn = PipedInputStream(toBridge, 1 shl 16)
        val out = ByteArrayOutputStream()
        var halfClosed = false
        fun end() = BridgeEnd(name, bridgeIn, out, { halfClosed = true })
    }

    @Test
    fun `bytes flow both ways and half close propagates on eof`() = runBlocking {
        val client = Capture("client")
        val remote = Capture("remote")
        withTimeout(5.seconds) {
            val bridge = StreamBridge(idleMs = 2000)
            val copyJob = async { bridge.copyBidirectional(client.end(), remote.end()) }

            client.toBridge.write("ping".toByteArray()); client.toBridge.flush()
            remote.toBridge.write("pong".toByteArray()); remote.toBridge.flush()
            client.toBridge.close() // client EOF -> remote output half-closed
            remote.toBridge.close()

            val (up, down) = copyJob.await()
            assertContentEquals("ping".toByteArray(), remote.out.toByteArray())
            assertContentEquals("pong".toByteArray(), client.out.toByteArray())
            assertEquals(4L, up)
            assertEquals(4L, down)
            assertTrue(remote.halfClosed)
            assertTrue(client.halfClosed)
        }
    }

    @Test
    fun `idle timeout tears down when no bytes move`() = runBlocking {
        val client = Capture("client")
        val remote = Capture("remote")
        withTimeout(5.seconds) {
            val bridge = StreamBridge(idleMs = 150)
            val (up, down) = bridge.copyBidirectional(client.end(), remote.end())
            assertEquals(0L, up)
            assertEquals(0L, down)
        }
    }

    @Test
    fun `one way response remains open while the request direction is quiet`() = runBlocking {
        val client = Capture("client")
        val remote = Capture("remote")
        withTimeout(5.seconds) {
            val copyJob = async {
                StreamBridge(idleMs = 400)
                    .copyBidirectional(client.end(), remote.end())
            }
            try {
                // A streamed response can keep sending while the completed request sends nothing.
                repeat(12) {
                    remote.toBridge.write(it)
                    remote.toBridge.flush()
                    delay(60)
                }
                assertFalse(copyJob.isCompleted, "active download must not expire the quiet upload direction")
                assertFalse(remote.halfClosed, "active response must not receive an artificial FIN")
                client.toBridge.close()
                remote.toBridge.close()
                assertEquals(0L to 12L, copyJob.await())
                assertContentEquals(ByteArray(12) { it.toByte() }, client.out.toByteArray())
            } finally {
                client.toBridge.close()
                remote.toBridge.close()
            }
        }
    }

    @Test
    fun `cancelling a bridge unblocks reads that ignore thread interruption`() = runBlocking {
        val started = CountDownLatch(2)
        val a = CloseOnlyInput(started)
        val b = CloseOnlyInput(started)
        val cleanup = Timer(true)
        // Keep a broken implementation from hanging the test worker forever.
        cleanup.schedule(object : TimerTask() {
            override fun run() { a.close(); b.close() }
        }, 1800)
        try {
            val copyJob = async {
                StreamBridge().copyBidirectional(
                    BridgeEnd("a", a, ByteArrayOutputStream(), {}),
                    BridgeEnd("b", b, ByteArrayOutputStream(), {}),
                )
            }
            assertTrue(withContext(Dispatchers.IO) { started.await(1, TimeUnit.SECONDS) })
            val before = System.nanoTime()
            copyJob.cancel()
            copyJob.join()
            assertTrue((System.nanoTime() - before) / 1_000_000 < 800,
                "cancellation must close blocked reads without waiting for remote traffic")
        } finally {
            a.close(); b.close(); cleanup.cancel()
        }
    }

    @Test
    fun `client EOF preserves a response beyond the old ten second grace`() = runBlocking {
        val client = Capture("client")
        val remote = Capture("remote")
        withTimeout(15.seconds) {
            val copy = async { StreamBridge(idleMs = 2000).copyBidirectional(client.end(), remote.end()) }
            try {
                client.toBridge.write("request".toByteArray())
                client.toBridge.close()
                repeat(12) {
                    remote.toBridge.write(it)
                    remote.toBridge.flush()
                    delay(950)
                }
                remote.toBridge.close()
                assertEquals(7L to 12L, copy.await())
                assertContentEquals(ByteArray(12) { it.toByte() }, client.out.toByteArray())
                assertTrue(remote.halfClosed)
            } finally {
                client.toBridge.close(); remote.toBridge.close()
            }
        }
    }
    @Test
    fun `half closed client with no response expires and releases sockets`() = runBlocking {
        val client = Capture("client")
        val started = CountDownLatch(1)
        val remoteRead = CloseOnlyInput(started)
        client.toBridge.close()
        withTimeout(2.seconds) {
            val result = StreamBridge(idleMs = 150).copyBidirectional(
                client.end(), BridgeEnd("remote", remoteRead, ByteArrayOutputStream(), {}),
            )
            assertEquals(0L to 0L, result)
        }
    }

    @Test
    fun `real IO failure closes the other blocked direction`() = runBlocking {
        val started = CountDownLatch(1)
        val blocked = CloseOnlyInput(started)
        val failed = object : InputStream() {
            override fun read(): Int { throw java.io.IOException("reset") }
        }
        try {
            withTimeout(2.seconds) {
                StreamBridge().copyBidirectional(
                    BridgeEnd("failed", failed, ByteArrayOutputStream(), {}),
                    BridgeEnd("blocked", blocked, ByteArrayOutputStream(), {}),
                )
            }
            throw AssertionError("socket error must propagate")
        } catch (error: java.io.IOException) {
            assertEquals("reset", error.message)
        } finally { blocked.close() }
    }

}
