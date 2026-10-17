package io.droidbridge.relay

import io.droidbridge.protocol.*
import io.droidbridge.policy.DestinationDeniedException
import io.droidbridge.network.AddressFamilyUnavailableException
import java.net.*
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.*

enum class UdpAssociationExitReason { EOF, PROTOCOL, IO, IDLE, CANCELLED, INTERNAL }

/** One authenticated stream owns one unconnected socket and a bounded, expiring peer allowlist. */
class UdpAssociationRelaySession(
    private val client: Socket,
    private val remote: DatagramSocket,
    private val request: UdpAssociationOpen,
    private val traffic: RelayTrafficPolicy,
    private val requireAllowed: (InetAddress) -> Unit,
    private val onDrop: (Long) -> Unit,
    private val onTransfer: (Long,Long) -> Unit,
    private val idleNanos: Long=request.idleSeconds*1_000_000_000L,
    private val onExit: (UdpAssociationExitReason) -> Unit = {},
) {
    private class PeerActivity(val touched: Long)

    suspend fun run() = withContext(Dispatchers.Default) {
        coroutineScope {
            val outbound=BoundedPacketQueue<RawAssociationDatagram>(sizeOf={ AssociationDatagramCodec.HEADER_SIZE+it.payload.size }) { onDrop(1) }
            val inbound=BoundedDatagramQueue { onDrop(1) }
            val peers=LinkedHashMap<InetSocketAddress,PeerActivity>()
            val ended=CompletableDeferred<UdpAssociationExitReason>()
            val touched=AtomicLong(System.nanoTime())
            val jobs=mutableListOf<Job>()
            fun worker(dispatcher: CoroutineDispatcher=Dispatchers.Default,normalReason: UdpAssociationExitReason=UdpAssociationExitReason.CANCELLED,block: suspend () -> Unit) {
                jobs+=launch(dispatcher) {
                    var reason=UdpAssociationExitReason.CANCELLED
                    try { block(); reason=normalReason }
                    catch(e: CancellationException) { throw e }
                    catch(_: DbpProtocolException) { reason=UdpAssociationExitReason.PROTOCOL; onDrop(1) }
                    catch(_: java.io.EOFException) { reason=UdpAssociationExitReason.PROTOCOL; onDrop(1) }
                    catch(_: java.io.IOException) { reason=UdpAssociationExitReason.IO }
                    catch(_: Exception) { reason=UdpAssociationExitReason.INTERNAL }
                    finally { ended.complete(reason) }
                }
            }
            fun expire(now: Long) { peers.entries.removeAll { now-it.value.touched>=idleNanos } }
            var exitReason=UdpAssociationExitReason.CANCELLED
            try {
                require(!remote.isConnected) { "association requires an unconnected socket" }
                // Keep each socket worker on its IO view so runInterruptible does not switch
                // dispatchers for every datagram. It still supplies cancellation interruption.
                // Sends one Mac datagram to its peer, granting the reply permission before the send
                // and restoring it if the send fails. Policy refusals and failed sends count as drops.
                fun sendToPeer(frame: RawAssociationDatagram) {
                    val address=if(request.family==4) InetAddress.getByAddress(frame.address) else Inet6Address.getByAddress(null,frame.address,-1)
                    try { requireAllowed(address) }
                    catch(_: DestinationDeniedException) { onDrop(1); return }
                    catch(_: AddressFamilyUnavailableException) { onDrop(1); return }
                    val endpoint=InetSocketAddress(address,frame.port)
                    val permission=PeerActivity(System.nanoTime())
                    val previous=synchronized(peers) {
                        expire(permission.touched)
                        val old=peers.remove(endpoint)
                        if(old==null && peers.size>=256) peers.remove(peers.keys.first())
                        peers[endpoint]=permission // Permission exists before a fast response can arrive.
                        old
                    }
                    try {
                        remote.send(DatagramPacket(frame.payload,frame.payload.size,endpoint))
                    } catch(e: java.io.IOException) {
                        synchronized(peers) {
                            if(previous==null) peers.remove(endpoint)
                            // A concurrent valid response owns a newer activity timestamp.
                            else if(peers[endpoint]===permission) peers[endpoint]=previous
                        }
                        if(remote.isClosed) throw e
                        onDrop(1); return
                    }
                    touched.set(System.nanoTime()); onTransfer(frame.payload.size.toLong(),0)
                }
                // Like the download direction: without upload shaping the reading thread sends each
                // datagram itself instead of waking a sender coroutine per packet.
                val directUp=traffic.profile.uploadBytesPerSecond==0
                worker(RelayDispatchers.socketReads,UdpAssociationExitReason.EOF) {
                    val input=java.io.BufferedInputStream(client.getInputStream(),16384)
                    var expected: Long?=null
                    fun sequenced(packet: RawAssociationDatagram) {
                        expected?.let { prior -> val gap=(packet.sequence-prior) and 0xffffffffL; if(gap>0) onDrop(gap) }
                        expected=(packet.sequence+1) and 0xffffffffL
                    }
                    if(directUp) runInterruptible(RelayDispatchers.socketReads) {
                        while(true) {
                            val packet=AssociationDatagramCodec.read(input,0,request.family) ?: break
                            sequenced(packet); sendToPeer(packet)
                        }
                    }
                    else while(isActive) {
                        val packet=runInterruptible(RelayDispatchers.socketReads) {
                            AssociationDatagramCodec.read(input,0,request.family)
                        } ?: break
                        sequenced(packet)
                        outbound.offer(packet)
                    }
                }
                if(!directUp) worker(RelayDispatchers.socketWrites) {
                    while(isActive) {
                        val frame=outbound.take() ?: break
                        traffic.upload(frame.payload.size)
                        runInterruptible(RelayDispatchers.socketWrites) { sendToPeer(frame) }
                    }
                }
                // Validates a received datagram and refreshes its peer permission; false drops it.
                fun permitted(packet: DatagramPacket): Boolean {
                    if(packet.length>AssociationDatagramCodec.MAX_PAYLOAD || packet.address.address.size!=(if(request.family==4) 4 else 16)) return false
                    val endpoint=packet.socketAddress as InetSocketAddress
                    return synchronized(peers) {
                        val now=System.nanoTime(); expire(now)
                        if(peers.remove(endpoint)==null) false
                        else { peers[endpoint]=PeerActivity(now); true }
                    }
                }
                // Without download shaping, the receiving thread writes each datagram straight to
                // the client: handing it to a writer coroutine woke a thread per packet, about 16%
                // of relay CPU on Parsec. Shaping still needs the queue, so it keeps that path.
                val direct=traffic.profile.downloadBytesPerSecond==0
                worker(RelayDispatchers.socketReads) {
                    val buffer=ByteArray(AssociationDatagramCodec.MAX_PAYLOAD+1)
                    var sequence=0L
                    if(direct) runInterruptible(RelayDispatchers.socketReads) {
                        val output=client.getOutputStream()
                        val packet=DatagramPacket(buffer,buffer.size)
                        while(true) {
                            packet.length=buffer.size // receive() shrinks it to the last datagram
                            remote.receive(packet)
                            if(!permitted(packet)) { onDrop(1); continue }
                            output.write(AssociationDatagramCodec.encode(buffer, packet.length, 1, sequence,
                                request.family, packet.address.address, packet.port))
                            sequence=(sequence+1) and 0xffffffffL
                            touched.set(System.nanoTime()); onTransfer(0,packet.length.toLong())
                        }
                    }
                    while(isActive) {
                        val packet=DatagramPacket(buffer,buffer.size)
                        runInterruptible(RelayDispatchers.socketReads) { remote.receive(packet) }
                        if(!permitted(packet)) { onDrop(1); continue }
                        inbound.offer(AssociationDatagramCodec.encode(buffer, packet.length, 1, sequence,
                            request.family, packet.address.address, packet.port))
                        sequence=(sequence+1) and 0xffffffffL
                        touched.set(System.nanoTime())
                    }
                }
                if(!direct) worker(RelayDispatchers.socketWrites) {
                    val batch=java.io.ByteArrayOutputStream(LOOPBACK_BATCH_BYTES)
                    while(isActive) {
                        // One loopback write per burst: per-datagram writes dominated relay CPU (Parsec).
                        val frames=inbound.takeAll(LOOPBACK_BATCH_BYTES) ?: break
                        val payloadSize=frames.sumOf { it.size }-frames.size*AssociationDatagramCodec.HEADER_SIZE
                        traffic.download(payloadSize)
                        batch.reset()
                        frames.forEach(batch::write)
                        runInterruptible(RelayDispatchers.socketWrites) { batch.writeTo(client.getOutputStream()) }
                        touched.set(System.nanoTime()); onTransfer(0,payloadSize.toLong())
                    }
                }
                worker(normalReason=UdpAssociationExitReason.IDLE) {
                    while(System.nanoTime()-touched.get()<idleNanos) delay((idleNanos/4_000_000).coerceIn(1,1000))
                }
                exitReason=ended.await()
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { exitReason=UdpAssociationExitReason.INTERNAL; throw e }
            finally {
                outbound.close(); inbound.close()
                remote.close(); runCatching { client.close() }
                jobs.forEach { it.cancel() }
                try { onExit(exitReason) } catch(_: Exception) { }
            }
        }
    }
}
