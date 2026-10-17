package io.droidbridge.network

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.droidbridge.protocol.DatagramCodec
import io.droidbridge.protocol.RawDatagram
import io.droidbridge.relay.RelayTrafficPolicy
import io.droidbridge.relay.UdpRelaySession
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket

@RunWith(AndroidJUnit4::class)
class UdpRelayInstrumentedTest {
    @Test fun ipv4RelayPreservesEmptyAndMaximumDatagrams() = checkRelay("127.0.0.1")
    @Test fun ipv6RelayPreservesEmptyAndMaximumDatagrams() = checkRelay("::1")

    private fun checkRelay(host: String) = runBlocking {
        val address = InetAddress.getByName(host)
        DatagramSocket(InetSocketAddress(address, 0)).use { echo ->
            echo.soTimeout = 2000
            val remote = AndroidDatagramSocket().apply { connect(echo.localSocketAddress) }
            ServerSocket(0, 1, address).use { listener ->
                Socket(address, listener.localPort).use { client ->
                    client.soTimeout = 2000
                    val peer = listener.accept()
                    val session = async(Dispatchers.IO) {
                        UdpRelaySession(peer, remote, 30, RelayTrafficPolicy(), {}, { _, _ -> }).run()
                    }
                    try {
                        for ((sequence, length) in listOf(0, 1, 0, 1232, 0).withIndex()) {
                            val bytes = ByteArray(length) { it.toByte() }
                            client.getOutputStream().write(DatagramCodec.encode(RawDatagram(bytes, 0, sequence.toLong())))
                            val received = DatagramPacket(ByteArray(1233), 1233)
                            withContext(Dispatchers.IO) { echo.receive(received) }
                            assertArrayEquals(bytes, received.data.copyOf(received.length))
                            echo.send(DatagramPacket(received.data, received.length, received.socketAddress))
                            assertArrayEquals(bytes, DatagramCodec.read(client.getInputStream(), 1)!!.payload)
                        }
                        client.shutdownOutput()
                        withTimeout(1500) { session.await() }
                        assertTrue(remote.isClosed)
                        assertTrue(peer.isClosed)
                    } finally {
                        client.close()
                        remote.close()
                        peer.close()
                        session.cancel()
                    }
                }
            }
        }
    }
}
