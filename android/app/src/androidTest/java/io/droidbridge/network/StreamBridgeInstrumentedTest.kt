package io.droidbridge.network

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.droidbridge.relay.BridgeEnd
import io.droidbridge.relay.StreamBridge
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.Timer
import java.util.TimerTask
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals

/** Loopback-only regression: no cellular traffic, USB access, or pairing changes. */
@RunWith(AndroidJUnit4::class)
class StreamBridgeInstrumentedTest {
    private fun end(name: String, socket: Socket) = BridgeEnd(
        name, socket.getInputStream(), socket.getOutputStream(), { socket.shutdownOutput() }, { socket.close() },
    )

    @Test fun streamedResponseKeepsQuietRequestDirectionAlive() = runBlocking {
        val loopback = InetAddress.getByName("127.0.0.1")
        ServerSocket(0, 2, loopback).use { listener ->
            Socket(loopback, listener.localPort).use { client ->
                listener.accept().use { a ->
                    Socket(loopback, listener.localPort).use { server ->
                        listener.accept().use { b ->
                            client.soTimeout = 2000
                            server.soTimeout = 2000
                            val cleanup = Timer(true)
                            cleanup.schedule(object : TimerTask() {
                                override fun run() { a.close(); b.close() }
                            }, 5000)
                            try {
                                val copy = async(Dispatchers.Default) {
                                    StreamBridge(idleMs = 400)
                                        .copyBidirectional(end("client", a), end("server", b))
                                }
                                repeat(12) {
                                    server.getOutputStream().write(it)
                                    assertEquals(it, client.getInputStream().read())
                                    delay(60)
                                }
                                // The request side was silent for more than one idle window.
                                client.getOutputStream().write(99)
                                assertEquals(99, server.getInputStream().read())
                                client.shutdownOutput()
                                server.shutdownOutput()
                                assertEquals(1L to 12L, copy.await())
                            } finally {
                                a.close(); b.close(); cleanup.cancel()
                            }
                        }
                    }
                }
            }
        }
    }
    @Test fun socketHalfClosePreservesLongReplyInBothDirections() = runBlocking {
        val loopback = InetAddress.getByName("127.0.0.1")
        // Swap which socket sends FIN first to exercise both copy jobs.
        repeat(2) { reverse ->
            ServerSocket(0, 2, loopback).use { listener ->
                Socket(loopback, listener.localPort).use { client ->
                    listener.accept().use { a ->
                        Socket(loopback, listener.localPort).use { server ->
                            listener.accept().use { b ->
                                client.soTimeout = 2500; server.soTimeout = 2500
                                val first = if (reverse == 0) client else server
                                val other = if (reverse == 0) server else client
                                val cleanup = Timer(true)
                                cleanup.schedule(object : TimerTask() {
                                    override fun run() { a.close(); b.close() }
                                }, 16000)
                                try {
                                    val copy = async(Dispatchers.Default) {
                                        StreamBridge(idleMs = 2000).copyBidirectional(end("client", a), end("server", b))
                                    }
                                    first.getOutputStream().write(99)
                                    first.shutdownOutput()
                                    assertEquals(99, other.getInputStream().read())
                                    assertEquals(-1, other.getInputStream().read())
                                    repeat(12) {
                                        other.getOutputStream().write(it)
                                        assertEquals(it, first.getInputStream().read())
                                        delay(950)
                                    }
                                    other.shutdownOutput()
                                    assertEquals(-1, first.getInputStream().read())
                                    assertEquals(if (reverse == 0) 1L to 12L else 12L to 1L, copy.await())
                                } finally { a.close(); b.close(); cleanup.cancel() }
                            }
                        }
                    }
                }
            }
        }
    }

}
