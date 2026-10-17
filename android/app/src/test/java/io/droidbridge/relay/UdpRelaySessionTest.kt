package io.droidbridge.relay

import io.droidbridge.protocol.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.net.*
import java.io.*

class UdpRelaySessionTest {
    @Test fun `typed queue retains packet ownership and counts header bytes for empty payloads`() = runBlocking {
        var drops=0
        val q=BoundedPacketQueue<RawAssociationDatagram>(2,56,{28+it.payload.size}) { drops++ }
        fun packet(seq: Long)=RawAssociationDatagram(ByteArray(0),0,seq,4,byteArrayOf(8,8,8,8),53)
        val first=packet(1); val second=packet(2); val third=packet(3)
        q.offer(first); q.offer(second); q.offer(third)
        assertSame(second,q.take()); assertSame(third,q.take()); assertEquals(1,drops)
        q.offer(packet(4).copy(payload=ByteArray(29)))
        assertEquals(2,drops)
        q.close(); assertNull(q.take())
    }

    @Test fun `queue drops oldest and never exceeds datagram or byte bounds`() = runBlocking {
        var drops=0L
        val q=BoundedDatagramQueue(2,5) { drops++ }
        q.offer(byteArrayOf(1,1)); q.offer(byteArrayOf(2,2)); q.offer(byteArrayOf(3,3))
        assertArrayEquals(byteArrayOf(2,2),q.take())
        assertArrayEquals(byteArrayOf(3,3),q.take())
        assertEquals(1,drops)
        q.offer(ByteArray(6)); assertEquals(2,drops)
        q.offer(ByteArray(0)); assertEquals(0,q.take()!!.size)
        q.close(); assertNull(q.take())
    }
    @Test fun `loopback UDP preserves zero and 1232 datagrams rejects oversize and closes on EOF`() = runBlocking {
        DatagramSocket(0,InetAddress.getLoopbackAddress()).use { echo ->
            echo.soTimeout=3000
            val remote=DatagramSocket().apply { connect(echo.localSocketAddress) }
            ServerSocket(0,1,InetAddress.getLoopbackAddress()).use { listener ->
                Socket(InetAddress.getLoopbackAddress(),listener.localPort).use { client ->
                    client.soTimeout=3000
                    val bridgeClient=listener.accept()
                    var drops=0L
                    val session=async(Dispatchers.IO) { UdpRelaySession(bridgeClient,remote,30,RelayTrafficPolicy(),{drops++},{_,_->}).run() }
                    for(length in listOf(0,1,1232)) {
                        val data=ByteArray(length) { it.toByte() }
                        client.getOutputStream().write(DatagramCodec.encode(RawDatagram(data,0,length.toLong())))
                        val received=DatagramPacket(ByteArray(2000),2000)
                        withContext(Dispatchers.IO) { echo.receive(received) }
                        assertEquals(length,received.length)
                        echo.send(DatagramPacket(received.data,received.length,received.socketAddress))
                        assertArrayEquals(data,DatagramCodec.read(client.getInputStream(),1)!!.payload)
                    }
                    echo.send(DatagramPacket(ByteArray(1233),1233,InetSocketAddress(InetAddress.getLoopbackAddress(),remote.localPort)))
                    echo.send(DatagramPacket(byteArrayOf(9),1,InetSocketAddress(InetAddress.getLoopbackAddress(),remote.localPort)))
                    assertArrayEquals(byteArrayOf(9),DatagramCodec.read(client.getInputStream(),1)!!.payload)
                    client.shutdownOutput()
                    withTimeout(1500) { session.await() }
                    assertTrue(remote.isClosed)
                    assertTrue(drops >= 1)
                }
            }
        }
    }
    @Test fun `idle session and cancelled shaped session release blocked readers`() = runBlocking {
        for(shaped in listOf(false,true)) {
            DatagramSocket().use { remote ->
                remote.connect(InetAddress.getLoopbackAddress(),9)
                ServerSocket(0,1,InetAddress.getLoopbackAddress()).use { listener ->
                    Socket(InetAddress.getLoopbackAddress(),listener.localPort).use { client ->
                        val peer=listener.accept()
                        val task=launch(Dispatchers.IO) { UdpRelaySession(peer,remote,30,RelayTrafficPolicy(if(shaped) TrafficProfile(uploadBytesPerSecond=1,burstBytes=1232) else TrafficProfile()),{},{_,_->},idleNanos=50_000_000).run() }
                        withTimeout(1500) { task.join() }
                        assertTrue(remote.isClosed)
                        assertTrue(peer.isClosed)
                    }
                }
            }
        }
    }
    @Test fun `invalid direction closes raw stream and records a drop`() = runBlocking {
        val remote=DatagramSocket().apply { connect(InetAddress.getLoopbackAddress(),9) }
        ServerSocket(0,1,InetAddress.getLoopbackAddress()).use { listener ->
            Socket(InetAddress.getLoopbackAddress(),listener.localPort).use { client ->
                val peer=listener.accept(); var drops=0L
                val task=async(Dispatchers.IO) { UdpRelaySession(peer,remote,30,RelayTrafficPolicy(),{drops+=it},{_,_->}).run() }
                client.getOutputStream().write(DatagramCodec.encode(RawDatagram(byteArrayOf(1),1,0)))
                withTimeout(1500) { task.await() }
                assertEquals(1,drops)
                assertTrue(remote.isClosed)
            }
        }
    }

}
