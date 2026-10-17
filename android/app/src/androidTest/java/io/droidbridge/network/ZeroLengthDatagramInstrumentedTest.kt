package io.droidbridge.network

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketException

@RunWith(AndroidJUnit4::class)
class ZeroLengthDatagramInstrumentedTest {
    @Test fun connectedAndUnconnectedDatagramsReachLoopback() {
        for (host in listOf("127.0.0.1", "::1")) {
            val address = InetAddress.getByName(host)
            for (explicitPolicy in listOf(false, true)) {
                for (connected in listOf(false, true)) {
                    DatagramSocket(InetSocketAddress(address, 0)).use { receiver ->
                        receiver.soTimeout = 2000
                        val sender = AndroidDatagramSocket().apply { bind(InetSocketAddress(address, 0)) }
                        try {
                            if (explicitPolicy) AndroidSocketPolicyApplier.apply(
                                sender, address, SocketEgressPolicy(ipv4Ttl = 65, ipv6HopLimit = 65),
                            )
                            if (connected) sender.connect(receiver.localSocketAddress)
                            for (length in listOf(0, 1, 0, 1232, 0)) {
                                val bytes = ByteArray(length) { it.toByte() }
                                sender.send(DatagramPacket(bytes, bytes.size, receiver.localSocketAddress))
                                val packet = DatagramPacket(ByteArray(1233), 1233)
                                receiver.receive(packet)
                                assertArrayEquals("$host policy=$explicitPolicy connected=$connected bytes=$length", bytes, packet.data.copyOf(packet.length))
                                assertFalse(sender.isClosed)
                            }
                        } finally { AndroidSocketPolicyApplier.release(sender) }
                    }
                }
            }
        }
    }

    @Test fun connectedEmptySendRejectsDifferentDestinationAndStillReceivesOnlyItsPeer() {
        val address = InetAddress.getByName("127.0.0.1")
        DatagramSocket(InetSocketAddress(address, 0)).use { peer ->
            DatagramSocket(InetSocketAddress(address, 0)).use { other ->
                AndroidDatagramSocket().use { sender ->
                    sender.bind(InetSocketAddress(address, 0))
                    sender.connect(peer.localSocketAddress)
                    try {
                        sender.send(DatagramPacket(ByteArray(0), 0, other.localSocketAddress))
                        fail("connected socket accepted a different destination")
                    } catch (_: IllegalArgumentException) { }
                    // A nonempty backing buffer and offset still represent one empty datagram.
                    val empty = DatagramPacket(byteArrayOf(1, 2, 3), 2, 0)
                    sender.send(empty)
                    peer.soTimeout = 2000
                    val received = DatagramPacket(ByteArray(8), 8)
                    peer.receive(received)
                    assertEquals(0, received.length)
                    assertEquals(peer.localSocketAddress, empty.socketAddress)
                    other.send(DatagramPacket(byteArrayOf(4), 1, sender.localSocketAddress))
                    peer.send(DatagramPacket(byteArrayOf(9), 1, sender.localSocketAddress))
                    sender.soTimeout = 2000
                    sender.receive(received)
                    assertArrayEquals(byteArrayOf(9), received.data.copyOf(received.length))
                }
            }
        }
    }

    @Test fun closeAfterEmptySendReleasesPortAndRejectsFurtherSends() {
        val address = InetAddress.getByName("127.0.0.1")
        DatagramSocket(InetSocketAddress(address, 0)).use { peer ->
            val sender = AndroidDatagramSocket().apply { bind(InetSocketAddress(address, 0)); connect(peer.localSocketAddress) }
            val local = sender.localSocketAddress
            sender.send(DatagramPacket(ByteArray(0), 0))
            sender.close()
            sender.close()
            assertTrue(sender.isClosed)
            try {
                sender.send(DatagramPacket(ByteArray(0), 0))
                fail("closed socket accepted an empty send")
            } catch (_: SocketException) { }
            // A retained duplicate would keep the UDP port bound after the Java socket closed.
            DatagramSocket(null).use { replacement -> replacement.bind(local) }
        }
    }
}
