package io.droidbridge.relay

import io.droidbridge.protocol.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.net.*
import java.util.concurrent.atomic.AtomicLong

class UdpAssociationRelaySessionTest {
    private val loopback=InetAddress.getByName("127.0.0.1")
    private suspend fun session(idleNanos: Long=30_000_000_000L,traffic: RelayTrafficPolicy=RelayTrafficPolicy(),remote: DatagramSocket=DatagramSocket(),
        body: suspend (Socket,DatagramSocket,Job,AtomicLong,AtomicLong) -> Unit) = coroutineScope {
        remote.use {
            ServerSocket(0,1,loopback).use { listener ->
                Socket(loopback,listener.localPort).use { client ->
                    client.soTimeout=2000
                    val peer=listener.accept(); val drops=AtomicLong(); val sent=AtomicLong()
                    val task=launch(Dispatchers.IO) {
                        UdpAssociationRelaySession(peer,remote,UdpAssociationOpen(4,30),traffic,{ require(it.isLoopbackAddress) },{drops.addAndGet(it)},{up,_->sent.addAndGet(up)},idleNanos).run()
                    }
                    try { body(client,remote,task,drops,sent) }
                    finally { client.close(); task.cancel(); withTimeout(1500) { task.join() } }
                    assertTrue(remote.isClosed); assertTrue(peer.isClosed)
                }
            }
        }
    }
    private fun send(client: Socket,peer: DatagramSocket,sequence: Long=0,payload: ByteArray=byteArrayOf(1)) {
        client.getOutputStream().write(AssociationDatagramCodec.encode(RawAssociationDatagram(payload,0,sequence,4,loopback.address,peer.localPort)))
    }
    private fun receive(peer: DatagramSocket)=DatagramPacket(ByteArray(2000),2000).also(peer::receive)
    @Test fun `idle expiry and cancellation close blocked socket workers`() = runBlocking {
        session(idleNanos=50_000_000) { _,_,task,_,_-> withTimeout(1500) { task.join() } }
        DatagramSocket(0,loopback).use { destination ->
            destination.soTimeout=2000
            session { client,_,task,_,_->
                send(client,destination); withContext(Dispatchers.IO) { receive(destination) }
                task.cancel(); withTimeout(1500) { task.join() }
            }
        }
    }
    @Test fun `cancellation discards shaped packet before it can send`() = runBlocking {
        DatagramSocket(0,loopback).use { peer ->
            peer.soTimeout=2000
            session(traffic=RelayTrafficPolicy(TrafficProfile(uploadBytesPerSecond=1,burstBytes=1232))) { client,_,task,_,sent ->
                send(client,peer,0,ByteArray(1232)); withContext(Dispatchers.IO) { receive(peer) }
                send(client,peer,1,ByteArray(1232))
                withTimeout(1500) { while(sent.get()!=1232L) delay(5) }
                task.cancel(); withTimeout(1500) { task.join() }
                peer.soTimeout=100
                try { receive(peer); fail("cancelled shaped packet escaped") } catch(_: SocketTimeoutException) {}
            }
        }
    }
    @Test fun `expired peer cannot respond while another peer keeps association alive`() = runBlocking {
        DatagramSocket(0,loopback).use { old -> DatagramSocket(0,loopback).use { active ->
            old.soTimeout=2000; active.soTimeout=2000
            session(idleNanos=200_000_000) { client,remote,_,drops,_ ->
                send(client,old); withContext(Dispatchers.IO) { receive(old) }
                repeat(6) { delay(50); send(client,active,it+1L); withContext(Dispatchers.IO) { receive(active) } }
                old.send(DatagramPacket(byteArrayOf(9),1,loopback,remote.localPort))
                withTimeout(1500) { while(drops.get()==0L) delay(5) }
                active.send(DatagramPacket(byteArrayOf(8),1,loopback,remote.localPort))
                val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)!!
                assertEquals(active.localPort,reply.port); assertArrayEquals(byteArrayOf(8),reply.payload)
            }
        } }
    }
    @Test fun `valid inbound traffic keeps its permitted peer alive until traffic stops`() = runBlocking {
        DatagramSocket(0,loopback).use { responding -> DatagramSocket(0,loopback).use { active ->
            responding.soTimeout=2000; active.soTimeout=2000
            session(idleNanos=200_000_000) { client,remote,_,drops,_ ->
                send(client,responding); withContext(Dispatchers.IO) { receive(responding) }
                repeat(8) { index ->
                    delay(50)
                    val payload=byteArrayOf(index.toByte())
                    responding.send(DatagramPacket(payload,payload.size,loopback,remote.localPort))
                    val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)
                    assertNotNull("active inbound peer expired after its initial outbound request",reply)
                    assertEquals(responding.localPort,reply!!.port); assertArrayEquals(payload,reply.payload)
                }
                assertEquals(0,drops.get())
                repeat(6) { delay(50); send(client,active,it+1L); withContext(Dispatchers.IO) { receive(active) } }
                responding.send(DatagramPacket(byteArrayOf(99),1,loopback,remote.localPort))
                withTimeout(1500) { while(drops.get()==0L) delay(5) }
                active.send(DatagramPacket(byteArrayOf(8),1,loopback,remote.localPort))
                val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)!!
                assertEquals(active.localPort,reply.port); assertArrayEquals(byteArrayOf(8),reply.payload)
            }
        } }
    }
    @Test fun `shaped downloads keep the queued path and still deliver inbound datagrams in order`() = runBlocking {
        val shaped=RelayTrafficPolicy(TrafficProfile(downloadBytesPerSecond=1_000_000,burstBytes=1232))
        DatagramSocket(0,loopback).use { responding ->
            responding.soTimeout=2000
            session(traffic=shaped) { client,remote,_,drops,_ ->
                send(client,responding); withContext(Dispatchers.IO) { receive(responding) }
                repeat(20) { responding.send(DatagramPacket(byteArrayOf(it.toByte()),1,loopback,remote.localPort)) }
                repeat(20) { index ->
                    val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)!!
                    assertArrayEquals(byteArrayOf(index.toByte()),reply.payload)
                }
                assertEquals(0,drops.get())
            }
        }
    }
    @Test fun `oversized inbound traffic cannot keep peer permission alive`() = runBlocking {
        DatagramSocket(0,loopback).use { oversized -> DatagramSocket(0,loopback).use { active ->
            oversized.soTimeout=2000; active.soTimeout=2000
            session(idleNanos=200_000_000) { client,remote,_,drops,_ ->
                send(client,oversized); withContext(Dispatchers.IO) { receive(oversized) }
                repeat(6) { index ->
                    delay(50)
                    oversized.send(DatagramPacket(ByteArray(DatagramCodec.MAX_PAYLOAD+1),DatagramCodec.MAX_PAYLOAD+1,loopback,remote.localPort))
                    withTimeout(1500) { while(drops.get()<index+1L) delay(5) }
                    send(client,active,index+1L); withContext(Dispatchers.IO) { receive(active) }
                }
                oversized.send(DatagramPacket(byteArrayOf(99),1,loopback,remote.localPort))
                withTimeout(1500) { while(drops.get()<7) delay(5) }
                active.send(DatagramPacket(byteArrayOf(8),1,loopback,remote.localPort))
                assertEquals(active.localPort,AssociationDatagramCodec.read(client.getInputStream(),1,4)!!.port)
            }
        } }
    }
    @Test fun `peer permission is bounded to 256 recently sent endpoints`() = runBlocking {
        val peers=(0..256).map { DatagramSocket(0,loopback) }
        try { session { client,remote,_,drops,sent ->
            peers.forEachIndexed { index,peer ->
                peer.soTimeout=2000; send(client,peer,index.toLong()); withContext(Dispatchers.IO) { receive(peer) }
            }
            withTimeout(3000) { while(sent.get()<257) delay(5) }
            peers.first().send(DatagramPacket(byteArrayOf(99),1,loopback,remote.localPort))
            withTimeout(1500) { while(drops.get()==0L) delay(5) }
            peers.last().send(DatagramPacket(byteArrayOf(7),1,loopback,remote.localPort))
            val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)!!
            assertEquals(peers.last().localPort,reply.port); assertArrayEquals(byteArrayOf(7),reply.payload)
        } } finally { peers.forEach { it.close() } }
    }
    @Test fun `failed later send does not erase concurrent accepted inbound activity`() = runBlocking {
        DatagramSocket(0,loopback).use { peer ->
            peer.soTimeout=2000
            val entered=CompletableDeferred<Unit>(); val release=java.util.concurrent.CountDownLatch(1)
            val remote=object: DatagramSocket() {
                var sends=0
                override fun send(packet: DatagramPacket) {
                    if(++sends==2) {
                        entered.complete(Unit)
                        check(release.await(2,java.util.concurrent.TimeUnit.SECONDS))
                        throw IOException("injected later send failure")
                    }
                    super.send(packet)
                }
            }
            try { session(idleNanos=400_000_000,remote=remote) { client,_,_,drops,_ ->
                send(client,peer); withContext(Dispatchers.IO) { receive(peer) }
                delay(200); send(client,peer,1)
                withTimeout(1500) { entered.await() }
                peer.send(DatagramPacket(byteArrayOf(7),1,loopback,remote.localPort))
                assertNotNull(AssociationDatagramCodec.read(client.getInputStream(),1,4))
                release.countDown()
                withTimeout(1500) { while(drops.get()<1) delay(5) }
                delay(250)
                peer.send(DatagramPacket(byteArrayOf(8),1,loopback,remote.localPort))
                val reply=AssociationDatagramCodec.read(client.getInputStream(),1,4)
                assertNotNull("failed send erased a newer inbound activity timestamp",reply)
                assertArrayEquals(byteArrayOf(8),reply!!.payload)
            } } finally { release.countDown() }
        }
    }
    @Test fun `failed initial send removes receive permission`() = runBlocking {
        DatagramSocket(0,loopback).use { denied -> DatagramSocket(0,loopback).use { allowed ->
            allowed.soTimeout=2000
            val remote=object: DatagramSocket() {
                override fun send(packet: DatagramPacket) {
                    if(packet.port==denied.localPort) throw IOException("injected send failure")
                    super.send(packet)
                }
            }
            session(remote=remote) { client,_,_,drops,_ ->
                send(client,denied)
                withTimeout(1500) { while(drops.get()<1) delay(5) }
                denied.send(DatagramPacket(byteArrayOf(99),1,loopback,remote.localPort))
                withTimeout(1500) { while(drops.get()<2) delay(5) }
                send(client,allowed,1); withContext(Dispatchers.IO) { receive(allowed) }
                allowed.send(DatagramPacket(byteArrayOf(8),1,loopback,remote.localPort))
                assertEquals(allowed.localPort,AssociationDatagramCodec.read(client.getInputStream(),1,4)!!.port)
            }
        } }
    }
}
