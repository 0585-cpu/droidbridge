package io.droidbridge.network

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.*

/** Run on API26 and API28 as well as modern Android: pre29 PFD wrappers borrow the original FD.
 * Compiled in software validation; run on devices only at final acceptance. */
@RunWith(AndroidJUnit4::class)
class SocketPolicyInstrumentedTest {
    @Test fun explicitTtlReadbackDoesNotCloseOriginalTcpSocket() {
        val loopback=InetAddress.getByName("127.0.0.1")
        ServerSocket(0,1,loopback).use { listener ->
            Socket().use { socket ->
                socket.bind(InetSocketAddress(loopback,0))
                for(ttl in listOf(1,64,65,255)) AndroidSocketPolicyApplier.apply(socket,loopback,SocketEgressPolicy(ipv4Ttl=ttl))
                socket.connect(listener.localSocketAddress)
                listener.accept().use { peer ->
                    socket.getOutputStream().write(9)
                    assertEquals(9,peer.getInputStream().read())
                    assertFalse(socket.isClosed)
                }
                AndroidSocketPolicyApplier.release(socket)
            }
        }
    }
    @Test fun hopLimitReadbackPreservesZeroLengthUdpSocket() {
        val loopback=Inet6Address.getByAddress(null,ByteArray(16).also {it[15]=1},-1)
        DatagramSocket(InetSocketAddress(loopback,0)).use { receiver ->
            receiver.soTimeout=2000
            AndroidDatagramSocket().apply { bind(InetSocketAddress(loopback,0)) }.use { sender ->
                for(hop in listOf(1,64,65,255)) AndroidSocketPolicyApplier.apply(sender,loopback,SocketEgressPolicy(ipv6HopLimit=hop))
                sender.connect(receiver.localSocketAddress)
                sender.send(DatagramPacket(ByteArray(0),0))
                val packet=DatagramPacket(ByteArray(2),2)
                receiver.receive(packet)
                assertEquals(0,packet.length)
                assertFalse(sender.isClosed)
                AndroidSocketPolicyApplier.release(sender)
            }
        }
    }
}
