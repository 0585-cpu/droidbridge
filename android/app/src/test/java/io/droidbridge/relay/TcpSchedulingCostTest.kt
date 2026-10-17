package io.droidbridge.relay

import java.io.DataInputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import org.junit.Test
import kotlin.test.*

/** Repeatable loopback workload; counts actual coroutine resumes without replacing IO. */
class TcpSchedulingCostTest {
    @Test fun bidirectionalTransferAndHalfCloseReportSchedulingCost() = runBlocking {
        val resumes = Resumes()
        val loopback = InetAddress.getLoopbackAddress()
        val rounds = 128
        val size = 8192
        ServerSocket(0, 1, loopback).use { local ->
            ServerSocket(0, 1, loopback).use { upstream ->
                Socket(loopback, local.localPort).use { client ->
                    val accepted = local.accept()
                    val remote = Socket(loopback, upstream.localPort)
                    upstream.accept().use { echo ->
                        listOf(client, accepted, remote, echo).forEach { it.tcpNoDelay = true; it.soTimeout = 3000 }
                        fun end(socket: Socket) = BridgeEnd("loopback", socket.getInputStream(), socket.getOutputStream(),
                            { socket.shutdownOutput() }, { socket.close() })
                        val bridge = async(Dispatchers.IO + resumes) {
                            StreamBridge().copyBidirectional(end(accepted), end(remote))
                        }
                        val reply = ByteArray(size)
                        val echoInput = DataInputStream(echo.getInputStream())
                        val clientInput = DataInputStream(client.getInputStream())
                        try {
                            repeat(rounds) { index ->
                                val payload = ByteArray(size) { (index + it).toByte() }
                                client.getOutputStream().write(payload)
                                echoInput.readFully(reply)
                                assertContentEquals(payload, reply)
                                echo.getOutputStream().write(reply)
                                clientInput.readFully(reply)
                                assertContentEquals(payload, reply)
                            }
                            client.shutdownOutput()
                            assertEquals(-1, echoInput.read(), "Client FIN must reach remote while replies remain possible")
                            echo.shutdownOutput()
                            assertEquals(-1, clientInput.read())
                            assertEquals(rounds.toLong() * size to rounds.toLong() * size,
                                withTimeout(3000) { bridge.await() })
                        } finally {
                            accepted.close(); remote.close(); bridge.cancel()
                            withTimeout(3000) { bridge.join() }
                        }
                    }
                }
            }
        }
        println("TCP scheduling: rounds=$rounds bytesPerDirection=${rounds * size} defaultResumes=${resumes.general.get()} readResumes=${resumes.reads.get()} writeResumes=${resumes.writes.get()}")
        assertTrue(resumes.general.get() < rounds / 4,
            "Stream copies must not return to general-purpose workers for every read and write")
        assertEquals(0L, resumes.writes.get(), "Stream copies must write on their read worker, not hop per chunk")
    }

    private class Resumes : ThreadContextElement<Unit>, AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<Resumes>
        val general = AtomicLong()
        val reads = AtomicLong()
        val writes = AtomicLong()
        override fun updateThreadContext(context: CoroutineContext) {
            when (context[ContinuationInterceptor]) {
                Dispatchers.Default -> general.incrementAndGet()
                RelayDispatchers.socketReads -> reads.incrementAndGet()
                RelayDispatchers.socketWrites -> writes.incrementAndGet()
            }
        }
        override fun restoreThreadContext(context: CoroutineContext, oldState: Unit) = Unit
    }
}
