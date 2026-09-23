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
class BoundedDatagramQueue(private val maxDatagrams: Int=64,private val maxBytes: Int=256*1024,private val onDrop: () -> Unit) {
    private val queue=ArrayDeque<ByteArray>()
    private val available=Channel<Unit>(Channel.CONFLATED)
    private var bytes=0
    private var closed=false
    init { require(maxDatagrams>0 && maxBytes>0) }
    @Synchronized fun offer(packet: ByteArray) {
        if(closed) return
        if(packet.size > maxBytes) { onDrop(); return }
        while(queue.size>=maxDatagrams || bytes+packet.size>maxBytes) { bytes-=queue.removeFirst().size; onDrop() }
        queue.addLast(packet); bytes+=packet.size; available.trySend(Unit)
    }
    suspend fun take(): ByteArray? {
        while(true) {
            synchronized(this) {
                if(queue.isNotEmpty()) return queue.removeFirst().also { bytes-=it.size }
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
            fun worker(block: suspend () -> Unit) {
                jobs+=launch {
                    try { block() } catch(e: CancellationException) { throw e } catch(_: DbpProtocolException) { onDrop(1) } catch(_: java.io.EOFException) { onDrop(1) } catch(_: Exception) { }
                    finally { ended.complete(Unit) }
                }
            }
            try {
                worker {
                    var expected: Long?=null
                    while(isActive) {
                        val frame=runInterruptible(RelayDispatchers.socketReads) { DatagramCodec.read(client.getInputStream(),0) } ?: break
                        expected?.let { prior -> val gap=(frame.sequence-prior) and 0xffffffffL; if(gap>0) onDrop(gap) }
                        expected=(frame.sequence+1) and 0xffffffffL
                        touched.set(System.nanoTime()); outbound.offer(frame.payload)
                    }
                }
                worker {
                    while(isActive) {
                        val bytes=outbound.take() ?: break
                        traffic.upload(bytes.size)
                        runInterruptible(RelayDispatchers.socketWrites) { remote.send(DatagramPacket(bytes,bytes.size)) }
                        touched.set(System.nanoTime()); onTransfer(bytes.size.toLong(),0)
                    }
                }
                worker {
                    // One byte above the maximum detects oversized/truncated datagrams without forwarding them.
                    val buffer=ByteArray(DatagramCodec.MAX_PAYLOAD+1)
                    while(isActive) {
                        val packet=DatagramPacket(buffer,buffer.size)
                        runInterruptible(RelayDispatchers.socketReads) { remote.receive(packet) }
                        if(packet.length>DatagramCodec.MAX_PAYLOAD) { onDrop(1); continue }
                        touched.set(System.nanoTime()); inbound.offer(buffer.copyOf(packet.length))
                    }
                }
                worker {
                    var sequence=0L
                    while(isActive) {
                        val bytes=inbound.take() ?: break
                        traffic.download(bytes.size)
                        val frame=DatagramCodec.encode(RawDatagram(bytes,1,sequence))
                        runInterruptible(RelayDispatchers.socketWrites) { client.getOutputStream().write(frame) }
                        sequence=(sequence+1) and 0xffffffffL
                        touched.set(System.nanoTime()); onTransfer(0,bytes.size.toLong())
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
