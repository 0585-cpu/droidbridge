package io.droidbridge.relay

import io.droidbridge.protocol.*
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Socket
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel

/** Nonblocking producer with simultaneous datagram and byte limits, including zero byte packets. */
class BoundedDatagramQueue(maxDatagrams: Int=64,maxBytes: Int=256*1024,onDrop: () -> Unit) :
    BoundedPacketQueue<ByteArray>(maxDatagrams,maxBytes,{ it.size },onDrop)

/** Takes ownership of a parsed immutable packet, avoiding a serialization round trip. */
open class BoundedPacketQueue<T>(private val maxDatagrams: Int=64,private val maxBytes: Int=256*1024,
    private val sizeOf: (T) -> Int, private val onDrop: () -> Unit) {
    private data class Entry<T>(val packet: T, val size: Int)
    private val queue=ArrayDeque<Entry<T>>()
    private val available=Channel<Unit>(Channel.CONFLATED)
    private var bytes=0
    private var closed=false
    init { require(maxDatagrams>0 && maxBytes>0) }
    @Synchronized fun offer(packet: T) {
        if(closed) return
        val size=sizeOf(packet)
        require(size>=0)
        if(size > maxBytes) { onDrop(); return }
        while(queue.size>=maxDatagrams || size>maxBytes-bytes) { bytes-=queue.removeFirst().size; onDrop() }
        queue.addLast(Entry(packet,size)); bytes+=size; available.trySend(Unit)
    }
    suspend fun take(): T? {
        while(true) {
            synchronized(this) {
                if(queue.isNotEmpty()) return queue.removeFirst().also { bytes-=it.size }.packet
                if(closed) return null
            }
            available.receiveCatching()
        }
    }
    /** Like [take], then also drains what is already queued while the batch stays within
     * [maxBytes] (always at least one packet), so a burst costs one consumer wakeup. */
    suspend fun takeAll(maxBytes: Int): List<T>? {
        while(true) {
            synchronized(this) {
                if(queue.isNotEmpty()) {
                    val batch=ArrayList<T>()
                    var total=0
                    while(queue.isNotEmpty() && (batch.isEmpty() || total+queue.first().size<=maxBytes)) {
                        val entry=queue.removeFirst(); bytes-=entry.size; total+=entry.size; batch+=entry.packet
                    }
                    return batch
                }
                if(closed) return null
            }
            available.receiveCatching()
        }
    }
    @Synchronized fun close() { closed=true; queue.clear(); bytes=0; available.close() }
}

/** A DBP OPEN_UDP connection switches permanently to raw framing. Four workers preserve datagram
 * boundaries and apply aggregate shaping behind bounded drop-oldest queues. EOF retires the flow. */
class UdpRelaySession(
    private val client: Socket,
    private val remote: DatagramSocket,
    idleSeconds: Int,
    private val traffic: RelayTrafficPolicy,
    private val onDrop: (Long) -> Unit,
    private val onTransfer: (Long,Long) -> Unit,
    private val idleNanos: Long=idleSeconds*1_000_000_000L,
) {
    suspend fun run() = withContext(Dispatchers.Default) {
        coroutineScope {
            val outbound=BoundedDatagramQueue { onDrop(1) }
            val inbound=BoundedDatagramQueue { onDrop(1) }
            val ended=CompletableDeferred<Unit>()
            val touched=AtomicLong(System.nanoTime())
            val jobs=mutableListOf<Job>()
            fun worker(dispatcher: CoroutineDispatcher=Dispatchers.Default,block: suspend () -> Unit) {
                jobs+=launch(dispatcher) {
                    try { block() } catch(e: CancellationException) { throw e } catch(_: DbpProtocolException) { onDrop(1) } catch(_: java.io.EOFException) { onDrop(1) } catch(_: Exception) { }
                    finally { ended.complete(Unit) }
                }
            }
            try {
                // Keep each socket worker on its IO view so runInterruptible does not switch
                // dispatchers for every datagram. It still supplies cancellation interruption.
                worker(RelayDispatchers.socketReads) {
                    val input=java.io.BufferedInputStream(client.getInputStream(),16384)
                    var expected: Long?=null
                    while(isActive) {
                        val frame=runInterruptible(RelayDispatchers.socketReads) { DatagramCodec.read(input,0) } ?: break
                        expected?.let { prior -> val gap=(frame.sequence-prior) and 0xffffffffL; if(gap>0) onDrop(gap) }
                        expected=(frame.sequence+1) and 0xffffffffL
                        touched.set(System.nanoTime()); outbound.offer(frame.payload)
                    }
                }
                worker(RelayDispatchers.socketWrites) {
                    while(isActive) {
                        val bytes=outbound.take() ?: break
                        traffic.upload(bytes.size)
                        runInterruptible(RelayDispatchers.socketWrites) { remote.send(DatagramPacket(bytes,bytes.size)) }
                        touched.set(System.nanoTime()); onTransfer(bytes.size.toLong(),0)
                    }
                }
                worker(RelayDispatchers.socketReads) {
                    // One byte above the maximum detects oversized/truncated datagrams without forwarding them.
                    val buffer=ByteArray(DatagramCodec.MAX_PAYLOAD+1)
                    while(isActive) {
                        val packet=DatagramPacket(buffer,buffer.size)
                        runInterruptible(RelayDispatchers.socketReads) { remote.receive(packet) }
                        if(packet.length>DatagramCodec.MAX_PAYLOAD) { onDrop(1); continue }
                        touched.set(System.nanoTime()); inbound.offer(buffer.copyOf(packet.length))
                    }
                }
                worker(RelayDispatchers.socketWrites) {
                    var sequence=0L
                    val batch=java.io.ByteArrayOutputStream(LOOPBACK_BATCH_BYTES)
                    while(isActive) {
                        // One loopback write per burst: per-datagram writes dominated relay CPU (Parsec).
                        val datagrams=inbound.takeAll(LOOPBACK_BATCH_BYTES) ?: break
                        val payloadSize=datagrams.sumOf { it.size }
                        traffic.download(payloadSize)
                        batch.reset()
                        for(bytes in datagrams) {
                            batch.write(DatagramCodec.encode(RawDatagram(bytes,1,sequence)))
                            sequence=(sequence+1) and 0xffffffffL
                        }
                        runInterruptible(RelayDispatchers.socketWrites) { batch.writeTo(client.getOutputStream()) }
                        touched.set(System.nanoTime()); onTransfer(0,payloadSize.toLong())
                    }
                }
                worker {
                    while(System.nanoTime()-touched.get()<idleNanos) delay((idleNanos/4_000_000).coerceIn(1,1000))
                }
                ended.await()
            } finally {
                outbound.close(); inbound.close()
                remote.close(); runCatching { client.close() }
                jobs.forEach { it.cancel() }
            }
        }
    }
}

/** Upper bound for one loopback write of queued datagrams (one AOA-sized read on the far side). */
internal const val LOOPBACK_BATCH_BYTES=16*1024
