package io.droidbridge.relay

import io.droidbridge.protocol.*
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicLong
import kotlin.coroutines.AbstractCoroutineContextElement
import kotlin.coroutines.ContinuationInterceptor
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class UdpSchedulingCostTest {
    @Test fun `association round trips do not resume general purpose workers per datagram`() = runBlocking {
        roundTrips(association=true)
    }

    @Test fun `connected UDP round trips do not resume general purpose workers per datagram`() = runBlocking {
        roundTrips(association=false)
    }

    private suspend fun roundTrips(association: Boolean) = coroutineScope {
        val loopback=InetAddress.getByName("127.0.0.1")
        val resumes=DispatcherResumes()
        val drops=AtomicLong()
        val uploads=AtomicLong()
        val downloads=AtomicLong()
        val count=128
        var totalBytes=0L
        DatagramSocket(0,loopback).use { echo ->
            echo.soTimeout=3000
            DatagramSocket(0,loopback).use { remote ->
                if(!association) remote.connect(echo.localSocketAddress)
                ServerSocket(0,1,loopback).use { listener ->
                    Socket(loopback,listener.localPort).use { client ->
                        client.soTimeout=3000
                        client.tcpNoDelay=true
                        val peer=listener.accept().apply { tcpNoDelay=true }
                        val transfer: (Long,Long) -> Unit={ up,down -> uploads.addAndGet(up); downloads.addAndGet(down) }
                        val task=launch(Dispatchers.IO+resumes) {
                            if(association) {
                                UdpAssociationRelaySession(peer,remote,UdpAssociationOpen(4,30),RelayTrafficPolicy(),
                                    { require(it.isLoopbackAddress) },{ drops.addAndGet(it) },transfer).run()
                            } else {
                                UdpRelaySession(peer,remote,30,RelayTrafficPolicy(),{ drops.addAndGet(it) },transfer).run()
                            }
                        }
                        try {
                            repeat(count) { index ->
                                val payload=ByteArray(if(index%8==0) 1232 else 256) { (index+it).toByte() }
                                totalBytes+=payload.size
                                val request=if(association) AssociationDatagramCodec.encode(
                                    RawAssociationDatagram(payload,0,index.toLong(),4,loopback.address,echo.localPort))
                                else DatagramCodec.encode(RawDatagram(payload,0,index.toLong()))
                                client.getOutputStream().write(request)
                                val packet=DatagramPacket(ByteArray(1233),1233)
                                echo.receive(packet)
                                assertArrayEquals(payload,packet.data.copyOf(packet.length))
                                echo.send(DatagramPacket(packet.data,packet.length,packet.socketAddress))
                                if(association) {
                                    val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)!!
                                    assertEquals(index.toLong(),reply.sequence)
                                    assertEquals(echo.localPort,reply.port)
                                    assertArrayEquals(loopback.address,reply.address)
                                    assertArrayEquals(payload,reply.payload)
                                } else {
                                    val reply=DatagramCodec.read(client.getInputStream(),1)!!
                                    assertEquals(index.toLong(),reply.sequence)
                                    assertArrayEquals(payload,reply.payload)
                                }
                            }
                            withTimeout(3000) { while(downloads.get()!=totalBytes) delay(1) }
                            client.shutdownOutput()
                            withTimeout(3000) { task.join() }
                            assertTrue(peer.isClosed)
                            assertTrue(remote.isClosed)
                        } finally {
                            task.cancel()
                            withTimeout(3000) { task.join() }
                        }
                    }
                }
            }
        }
        assertEquals(0L,drops.get())
        assertEquals(totalBytes,uploads.get())
        assertEquals(totalBytes,downloads.get())
        println("UDP scheduling cost: association=$association packetsPerDirection=$count bytesPerDirection=$totalBytes " +
            "defaultResumes=${resumes.general.get()} readResumes=${resumes.reads.get()} writeResumes=${resumes.writes.get()}")
        // Setup, the supervisor, and the idle timer may use Default. Returning there after
        // every blocking socket operation adds scheduler work proportional to packet rate.
        assertTrue("$count round trips caused ${resumes.general.get()} general-purpose resumes",
            resumes.general.get()<count/4)
    }

    /** Observes the real session's coroutine resumes without replacing its sockets or dispatchers. */
    private class DispatcherResumes : ThreadContextElement<Unit>, AbstractCoroutineContextElement(Key) {
        companion object Key : CoroutineContext.Key<DispatcherResumes>
        val general=AtomicLong()
        val reads=AtomicLong()
        val writes=AtomicLong()
        override fun updateThreadContext(context: CoroutineContext) {
            when(context[ContinuationInterceptor]) {
                Dispatchers.Default -> general.incrementAndGet()
                RelayDispatchers.socketReads -> reads.incrementAndGet()
                RelayDispatchers.socketWrites -> writes.incrementAndGet()
            }
        }
        override fun restoreThreadContext(context: CoroutineContext,oldState: Unit) {}
    }
}
