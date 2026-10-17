package io.droidbridge.network

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.droidbridge.protocol.AssociationDatagramCodec
import io.droidbridge.protocol.RawAssociationDatagram
import io.droidbridge.protocol.UdpAssociationOpen
import io.droidbridge.relay.RelayTrafficPolicy
import io.droidbridge.relay.UdpAssociationRelaySession
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.*

/** Exercises the phone's unconnected DatagramSocket implementation, including JNI zero sends. */
@RunWith(AndroidJUnit4::class)
class UdpAssociationInstrumentedTest {
    @Test fun ipv4PeersSharePhoneSocket() = checkFamily("127.0.0.1", 4)
    @Test fun ipv6PeersSharePhoneSocket() = checkFamily("::1", 6)

    private fun checkFamily(host: String, family: Int) = runBlocking {
        val address = InetAddress.getByName(host)
        DatagramSocket(InetSocketAddress(address, 0)).use { first ->
            DatagramSocket(InetSocketAddress(address, 0)).use { second ->
                first.soTimeout = 2000; second.soTimeout = 2000
                val remote = AndroidDatagramSocket().apply { bind(InetSocketAddress(address, 0)) }
                ServerSocket(0, 1, address).use { listener ->
                    Socket(address, listener.localPort).use { client ->
                        client.soTimeout = 2000
                        val stream = listener.accept()
                        val session = async(Dispatchers.IO) {
                            UdpAssociationRelaySession(stream, remote, UdpAssociationOpen(family, 30),
                                RelayTrafficPolicy(), {}, {}, { _, _ -> }).run()
                        }
                        try {
                            var source: SocketAddress? = null
                            for ((sequence, length) in listOf(0, 1, 1232, 0).withIndex()) {
                                val peer = if (sequence % 2 == 0) first else second
                                val payload = ByteArray(length) { it.toByte() }
                                client.getOutputStream().write(AssociationDatagramCodec.encode(
                                    RawAssociationDatagram(payload, 0, sequence.toLong(), family, address.address, peer.localPort)))
                                val received = DatagramPacket(ByteArray(1233), 1233)
                                withContext(Dispatchers.IO) { peer.receive(received) }
                                assertArrayEquals(payload, received.data.copyOf(received.length))
                                if (source == null) source = received.socketAddress
                                assertEquals("both destinations must see the same phone socket", source, received.socketAddress)
                                peer.send(DatagramPacket(received.data, received.length, received.socketAddress))
                                val reply = AssociationDatagramCodec.read(client.getInputStream(), 1, family)!!
                                assertEquals(peer.localPort, reply.port)
                                assertArrayEquals(address.address, reply.address)
                                assertArrayEquals(payload, reply.payload)
                            }
                            client.shutdownOutput()
                            withTimeout(2000) { session.await() }
                            assertTrue(remote.isClosed)
                            assertTrue(stream.isClosed)
                        } finally {
                            client.close(); remote.close(); stream.close(); session.cancel()
                        }
                    }
                }
            }
        }
    }
}
