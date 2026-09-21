package io.droidbridge.relay

import java.io.ByteArrayOutputStream
import java.io.PipedInputStream
import java.io.PipedOutputStream
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

@OptIn(ExperimentalCoroutinesApi::class)
class StreamBridgeTest {
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
            val bridge = StreamBridge(idleMs = 2000, graceMs = 200)
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
            val bridge = StreamBridge(idleMs = 150, graceMs = 100)
            val (up, down) = bridge.copyBidirectional(client.end(), remote.end())
            assertEquals(0L, up)
            assertEquals(0L, down)
        }
    }
}
