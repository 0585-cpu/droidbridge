package io.droidbridge.usb

import org.junit.Assert.*
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.Executors

class AoaAccessoryBridgeTest {
    @Suppress("DEPRECATION") // Thread.id is available on the project's Java 17 test runtime.
    @Test fun smallSocketRepliesDoNotAllocateAFullUsbBufferPerRead() {
        val allocations = java.lang.management.ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        org.junit.Assume.assumeTrue(allocations?.isThreadAllocatedMemorySupported == true)
        allocations!!
        allocations.isThreadAllocatedMemoryEnabled = true
        val previousThreads = Thread.getAllStackTraces().keys.map { it.id }.toSet()
        ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            host.tcpNoDelay = true
            val accessory = usb.accept().apply { tcpNoDelay = true }
            ServerSocket(0).use { relay ->
                relay.soTimeout = 5000
                val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                    relay.localPort, relay.localPort, { accessory.close() })
                bridge.start()
                try {
                    val input = BufferedInputStream(host.getInputStream())
                    fun send(frame: AoaFrame) { host.getOutputStream().write(frame.encode()) }
                    send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)))
                    assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                    send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY))
                    relay.accept().use { peer ->
                        peer.tcpNoDelay = true
                        assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                        val selector = Thread.getAllStackTraces().keys.single {
                            it.name == "aoa-sockets" && it.id !in previousThreads
                        }
                        val before = allocations.getThreadAllocatedBytes(selector.id)
                        repeat(256) { index ->
                            val payload = ByteArray(32) { (index + it).toByte() }
                            peer.getOutputStream().write(payload)
                            val frame = AoaFrame.read(input)!!
                            assertEquals(AoaFrame.DATA, frame.type)
                            assertArrayEquals(payload, frame.payload)
                        }
                        val allocated = allocations.getThreadAllocatedBytes(selector.id) - before
                        // 8 KiB of real payload should not need 4 MiB of temporary read buffers.
                        // The generous bound includes all selector bookkeeping/frame allocations.
                        assertTrue("selector allocated $allocated bytes for 8 KiB of replies", allocated in 0..2_097_152L)
                        println("selector allocation for 256 replies: $allocated bytes")
                    }
                } finally { bridge.close() }
            }
        } }
    }

    @Test fun repeatsConsumedWindowWhenTheFirstUpdateIsLost() {
        ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            val accessory = usb.accept()
            ServerSocket(0).use { relay ->
                relay.soTimeout = 5000
                val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                    relay.localPort, relay.localPort, { accessory.close() })
                bridge.start()
                try {
                    val input = BufferedInputStream(host.getInputStream())
                    fun send(frame: AoaFrame) { host.getOutputStream().write(frame.encode()) }
                    send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)))
                    assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                    send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY))
                    relay.accept().use { peer ->
                        peer.soTimeout = 5000
                        assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                        val payload = ByteArray(16384) { 7 }
                        send(AoaFrame(AoaFrame.DATA, 1, payload = payload))
                        assertArrayEquals(payload, peer.getInputStream().readNBytes(payload.size))
                        host.soTimeout = 500 // Sparse updates must not wait for the 2s refresh.
                        val lost = AoaFrame.read(input)!! // deliberately discard the first update
                        host.soTimeout = 5000
                        val repeated = AoaFrame.read(input)!!
                        assertEquals(AoaFrame.WINDOW, repeated.type)
                        assertArrayEquals(lost.payload, repeated.payload)
                    }
                } finally { bridge.close() }
            }
        } }
    }

    @Test fun transfersBinaryDataLargerThanTheWindowInBothDirections() {
        val payload = ByteArray(262144) { (it * 31).toByte() }
        val executor = Executors.newSingleThreadExecutor()
        try {
            ServerSocket(0).use { usb ->
                Socket("127.0.0.1", usb.localPort).use { host ->
                    host.soTimeout = 5000
                    val accessory = usb.accept()
                    ServerSocket(0).use { relay ->
                        relay.soTimeout = 5000
                        val echoed = executor.submit<Boolean> {
                            relay.accept().use { peer ->
                                peer.soTimeout = 5000
                                val received = peer.getInputStream().readNBytes(payload.size)
                                assertEquals(-1, peer.getInputStream().read())
                                peer.getOutputStream().write(received)
                                peer.shutdownOutput()
                                received.contentEquals(payload)
                            }
                        }
                        val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                            relay.localPort, relay.localPort, { accessory.close() })
                        bridge.start()
                        try {
                            val input = BufferedInputStream(host.getInputStream())
                            fun send(frame: AoaFrame) { host.getOutputStream().write(frame.encode()) }
                            send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)))
                            assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                            send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY))
                            assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                            var credit = AoaFrame.INITIAL_CREDIT
                            for (offset in payload.indices step AoaFrame.MAX_PAYLOAD) {
                                while (credit < AoaFrame.MAX_PAYLOAD) {
                                    val window = AoaFrame.read(input)!!
                                    assertEquals(AoaFrame.WINDOW, window.type)
                                    credit = AoaFrame.INITIAL_CREDIT - (offset.toLong() - window.credit()).toInt()
                                }
                                send(AoaFrame(AoaFrame.DATA, 1, payload = payload.copyOfRange(offset, offset + AoaFrame.MAX_PAYLOAD)))
                                credit -= AoaFrame.MAX_PAYLOAD
                            }
                            send(AoaFrame(AoaFrame.FIN, 1))
                            val received = ByteArrayOutputStream()
                            while (true) {
                                val frame = AoaFrame.read(input)!!
                                when (frame.type) {
                                    AoaFrame.WINDOW -> Unit
                                    AoaFrame.DATA -> {
                                        received.write(frame.payload)
                                        send(AoaFrame.window(1, received.size().toLong()))
                                    }
                                    AoaFrame.FIN -> break
                                    else -> fail("unexpected frame ${frame.type}")
                                }
                            }
                            assertArrayEquals(payload, received.toByteArray())
                            assertTrue(echoed.get(5, TimeUnit.SECONDS))
                        } finally { bridge.close() }
                    }
                }
            }
        } finally { executor.shutdownNow() }
    }

    @Test fun duplicateAndStaleConsumedCountsDoNotInflateTheWindow() {
        val payload = ByteArray(196608) { (it * 17).toByte() }
        val executor = Executors.newSingleThreadExecutor()
        try { ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            val accessory = usb.accept()
            ServerSocket(0).use { relay ->
                relay.soTimeout = 5000
                val written = executor.submit { relay.accept().use { peer ->
                    peer.getOutputStream().write(payload)
                    peer.shutdownOutput()
                } }
                val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                    relay.localPort, relay.localPort, { accessory.close() })
                bridge.start()
                try {
                    val input = BufferedInputStream(host.getInputStream())
                    fun send(frame: AoaFrame) { host.getOutputStream().write(frame.encode()) }
                    send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)))
                    assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                    send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY))
                    assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                    val received = ByteArrayOutputStream()
                    while (received.size() < AoaFrame.INITIAL_CREDIT) {
                        val frame = AoaFrame.read(input)!!
                        assertEquals(AoaFrame.DATA, frame.type)
                        received.write(frame.payload)
                    }
                    // Pretend all intermediate updates were lost. One cumulative update recovers
                    // the whole window; repeats and older updates must not grant it again.
                    send(AoaFrame.window(1, received.size().toLong()))
                    send(AoaFrame.window(1, received.size().toLong()))
                    send(AoaFrame.window(1, 16384))
                    while (received.size() < 2 * AoaFrame.INITIAL_CREDIT) {
                        val frame = AoaFrame.read(input)!!
                        assertEquals(AoaFrame.DATA, frame.type)
                        received.write(frame.payload)
                    }
                    host.soTimeout = 300
                    try {
                        AoaFrame.read(input)
                        fail("duplicate ACK granted bytes beyond the receive window")
                    } catch (_: java.net.SocketTimeoutException) { /* correct: no credit left */ }
                    host.soTimeout = 5000
                    send(AoaFrame.window(1, received.size().toLong()))
                    while (true) {
                        val frame = AoaFrame.read(input)!!
                        if (frame.type == AoaFrame.FIN) break
                        assertEquals(AoaFrame.DATA, frame.type)
                        received.write(frame.payload)
                        send(AoaFrame.window(1, received.size().toLong()))
                    }
                    assertArrayEquals(payload, received.toByteArray())
                    written.get(5, TimeUnit.SECONDS)
                } finally { bridge.close() }
            }
        } } } finally { executor.shutdownNow() }
    }

    @Test fun multiplexesFixedServicesAndPreservesHalfClose() {
        ServerSocket(0).use { usb ->
            Socket("127.0.0.1", usb.localPort).use { host ->
                host.soTimeout = 5000
                val accessory = usb.accept()
                ServerSocket(0).use { relay ->
                    ServerSocket(0).use { pairing ->
                        relay.soTimeout = 5000
                        pairing.soTimeout = 5000
                        val ended = CountDownLatch(1)
                        val bridge = AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                            relay.localPort, pairing.localPort, { accessory.close() }) { ended.countDown() }
                        bridge.start()
                        try {
                            val input = BufferedInputStream(host.getInputStream())
                            fun send(frame: AoaFrame) { host.getOutputStream().write(frame.encode()) }
                            val nonce = ByteArray(16) { it.toByte() }
                            send(AoaFrame(AoaFrame.RESET, 0, payload = nonce))
                            assertArrayEquals(nonce, AoaFrame.read(input)!!.payload)
                            send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.RELAY))
                            relay.accept().use { peer ->
                                peer.soTimeout = 5000
                                assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                                send(AoaFrame(AoaFrame.DATA, 1, payload = byteArrayOf(1, 2, 3)))
                                assertArrayEquals(byteArrayOf(1, 2, 3), peer.getInputStream().readNBytes(3))
                                assertEquals(3L, AoaFrame.read(input)!!.credit())
                                send(AoaFrame(AoaFrame.FIN, 1))
                                assertEquals(-1, peer.getInputStream().read())
                                peer.getOutputStream().write(byteArrayOf(9, 8))
                                peer.shutdownOutput()
                                assertArrayEquals(byteArrayOf(9, 8), AoaFrame.read(input)!!.payload)
                                assertEquals(AoaFrame.FIN, AoaFrame.read(input)!!.type)
                            }
                            // Reclaiming the same accessory starts a new epoch without reusing old streams.
                            send(AoaFrame(AoaFrame.RESET, 0, payload = nonce))
                            assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                            send(AoaFrame(AoaFrame.OPEN, 1, AoaFrame.PAIRING))
                            pairing.accept().use {
                                var frame = AoaFrame.read(input)!!
                                if (frame.type == AoaFrame.CLOSE) frame = AoaFrame.read(input)!!
                                assertEquals(1, frame.streamId)
                                assertEquals(AoaFrame.OPEN_OK, frame.type)
                                // Peer cannot increase its window beyond the agreed receive capacity.
                                send(AoaFrame.window(1, 1))
                                assertTrue(ended.await(5, TimeUnit.SECONDS))
                                assertEquals(-1, host.getInputStream().read())
                            }
                        } finally { bridge.close() }
                    }
                }
            }
        }
    }
}
