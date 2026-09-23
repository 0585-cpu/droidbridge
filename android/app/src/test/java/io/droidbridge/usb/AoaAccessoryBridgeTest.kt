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
                                    credit += window.credit()
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
                                        send(AoaFrame.window(1, frame.payload.size))
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
                                assertEquals(3, AoaFrame.read(input)!!.credit())
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
