package io.droidbridge.usb

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.SocketChannel
import java.util.ArrayDeque
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/** USB framing and loopback forwarding only. RelayServer still authenticates every DBP stream. */
class AoaAccessoryBridge(
    private val input: InputStream,
    private val output: OutputStream,
    private val relayPort: Int = 27183,
    private val pairingPort: Int = 27184,
    private val closeTransport: () -> Unit,
    private val onReadFailure: (ReadFailure) -> Unit = {},
    private val onStreamIdle: (StreamIdle) -> Unit = {},
    private val onClosed: (String) -> Unit = {},
    // Serves a RELAY stream in memory (false: relay not running). Null keeps the loopback socket.
    private val relayAcceptor: ((java.net.Socket) -> Boolean)? = null,
    private val onSessionActive: (Boolean) -> Unit = {},
) : Closeable {
    /** Fixed-size diagnostics contain only validated frame metadata, never USB contents. */
    data class ReadFailure(val completedFrames: Long, val completedBytes: Long,
                           val lastType: Int?, val lastPayloadBytes: Int?)
    data class StreamIdle(val id: Int, val sentBytes: Long, val receivedBytes: Long,
                          val sendCredit: Int, val receiveCredit: Int, val pendingWrites: Int,
                          val outgoingFrames: Int)

    private class Stream(val id: Int, val socket: SocketChannel) {
        var connected = false
        var localFin = false
        var remoteFin = false
        var outputShutdown = false
        var sendCredit = AoaFrame.INITIAL_CREDIT
        var receiveCredit = AoaFrame.INITIAL_CREDIT
        var sentBytes = 0L
        var receivedBytes = 0L
        var consumedBytes = 0L
        val windowUpdate = AoaWindowUpdate()
        var refreshedConsumed = 0L
        var peerConsumedBytes = 0L
        var lastSent = System.nanoTime()
        var idleReported = false
        val writes = ArrayDeque<ByteBuffer>()
        val deadline = System.nanoTime() + 5_000_000_000L
    }
    private val selector = Selector.open()
    private val incoming = ArrayBlockingQueue<AoaFrame>(1024)
    private val outgoing = ArrayBlockingQueue<ByteArray>(1024)
    // Reserve room for WINDOW/FIN/OPEN replies while bulk socket reads are paused.
    private val dataHighWater = 256
    private val stopped = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    // Only the selector thread accesses streams and lastId.
    private val streams = mutableMapOf<Int, Stream>()
    // Selector-owned scratch space. DATA frames copy their payload before it is reused.
    private val socketReadBuffer = ByteBuffer.allocate(AoaFrame.SEND_PAYLOAD)
    private var lastId = 0
    @Volatile private var sessionReady = false
    @Volatile private var lastHostActivity = System.nanoTime()
    private var lastWindowRefresh = System.nanoTime()
    private var lastHousekeeping = System.nanoTime()
    // Selector-owned: streams with an unsent WINDOW deadline, and streams whose interest ops
    // were narrowed only by the global writer backlog. Avoids scanning every stream per frame.
    private val windowPending = LinkedHashSet<Stream>()
    // In-memory RELAY streams. The reader thread opens them and handles all their frames in order
    // (no selector hop per packet); relay threads and session teardown may remove or abort them.
    private val pipes = java.util.concurrent.ConcurrentHashMap<Int, AoaPipeSocket>()
    // Reader-owned: stream-ID order for every OPEN, and the IDs whose OPEN went to the selector.
    private var readerLastId = 0
    private val selectorIds = HashSet<Int>()
    private val backlog = Object() // relay-thread senders wait here for the writer to drain
    // Fences relay-thread frames against RESET: after RESET_OK the host reuses stream IDs from 1,
    // so a late frame of an aborted pipe would land in a new stream or kill the session.
    private val relaySendLock = Object()
    private val readBlocked = LinkedHashSet<Stream>()  // reads/connect wait for outgoing < high water
    private val writeBlocked = LinkedHashSet<Stream>() // local writes wait for a free outgoing slot
    private var reader: Thread? = null
    private var writer: Thread? = null
    @Volatile private var readProgress = ReadFailure(0, 0, null, null)
    private val readFailureReported = AtomicBoolean(false)

    fun start() {
        check(started.compareAndSet(false, true) && !stopped.get())
        writer = worker("aoa-writer") {
            val batch = ByteArray(AoaFrame.WRITE_BUDGET)
            while (!stopped.get()) {
                val first = outgoing.take()
                var taken = 1
                var length = first.size
                if (first.size <= batch.size) {
                    // One record per batch instead of per frame: WINDOW/FIN/PONG/small DATA
                    // otherwise each pay a record header, two digests and a USB transfer. No
                    // waiting for more: a 1 ms coalescing window cut no measured CPU on Parsec.
                    first.copyInto(batch)
                    while (true) {
                        val next = outgoing.peek() ?: break // sole consumer: peek then poll is safe
                        if (length + next.size > batch.size) break
                        outgoing.poll()!!.copyInto(batch, length)
                        length += next.size
                        taken++
                    }
                }
                // Wake before the blocking write so the selector refills while USB drains. Range
                // check, not equality: taking several frames at once can skip any single size.
                val after = outgoing.size
                val before = after + taken
                if ((before >= dataHighWater && after < dataHighWater) || (before >= 1024 && after < 1024)) {
                    selector.wakeup()
                    synchronized(backlog) { backlog.notifyAll() }
                }
                if (first.size > batch.size) output.write(first) // never produced locally; the channel splits it
                else output.write(batch, 0, length)
            }
        }
        reader = worker("aoa-reader") {
            var frames = 0L
            var bytes = 0L
            var lastType: Int? = null
            var lastPayloadBytes: Int? = null
            while (!stopped.get()) {
                val frame = try {
                    AoaFrame.read(input) ?: throw IOException("USB disconnected")
                } catch (error: IOException) {
                    // One bounded record per failed reader, before recovery starts. Keep the
                    // original failure reason and never inspect/log an unvalidated header.
                    if (!stopped.get()) reportReadFailure()
                    throw error
                }
                frames++
                bytes += 16L + frame.payload.size
                lastType = frame.type
                lastPayloadBytes = frame.payload.size
                readProgress = ReadFailure(frames, bytes, lastType, lastPayloadBytes)
                lastHostActivity = System.nanoTime()
                if (routeOnReader(frame)) continue
                incoming.put(frame) // bounded backpressure; temporary congestion is not corruption
                selector.wakeup()
            }
        }
        Thread({
            try {
                while (!stopped.get()) {
                    val waitMillis = flushWindowsAndWait(System.nanoTime())
                    if (incoming.isNotEmpty() && outgoing.size < dataHighWater) selector.selectNow() else selector.select(waitMillis)
                    releaseBacklogBlocked()
                    // Bound each batch so a busy USB peer cannot starve socket IO.
                    for (index in 0 until 1024) {
                        if (outgoing.size >= dataHighWater) break
                        val frame = incoming.poll() ?: break
                        handle(frame)
                    }
                    val selected = selector.selectedKeys().iterator()
                    while (selected.hasNext()) {
                        val key = selected.next()
                        selected.remove()
                        if (!key.isValid) continue
                        val stream = key.attachment() as Stream
                        try {
                            if (outgoing.remainingCapacity() > 0 && key.isConnectable && stream.socket.finishConnect()) opened(stream)
                            if (key.isValid && key.isWritable && outgoing.remainingCapacity() > 0) writeLocal(stream)
                            if (key.isValid && key.isReadable && outgoing.size < dataHighWater) readLocal(stream)
                            // A ready op skipped for backlog must leave the interest set, or the
                            // level-triggered selector returns at once and the loop spins.
                            if (key.isValid) interests(stream)
                        } catch (_: IOException) { retire(stream.id, true) }
                    }
                    releaseBacklogBlocked()
                    val now = System.nanoTime()
                    // Whole-table scans run on a fixed cadence, never once per USB frame.
                    if (now - lastHousekeeping < HOUSEKEEPING_NANOS) continue
                    lastHousekeeping = now
                    streams.values.filter { !it.connected && now > it.deadline }
                        .forEach { retire(it.id, true) }
                    if (sessionReady && now - lastWindowRefresh >= 2_000_000_000L) {
                        lastWindowRefresh = now
                        // Only consumption not yet repeated: idle streams cost nothing, and a
                        // lost update is still repeated once without new data.
                        streams.values.filter { it.connected && it.consumedBytes > it.refreshedConsumed }.forEach {
                            if (outgoing.remainingCapacity() > 0) { sendWindow(it); it.refreshedConsumed = it.consumedBytes }
                        }
                    }
                    streams.values.filter { it.sentBytes >= 1_048_576 && !it.localFin && !it.idleReported &&
                        now - it.lastSent >= 10_000_000_000L }.forEach {
                        it.idleReported = true
                        runCatching { onStreamIdle(StreamIdle(it.id, it.sentBytes, it.receivedBytes,
                            it.sendCredit, it.receiveCredit, it.writes.size, outgoing.size)) }
                    }
                    // Outlast the outer channel's no-progress deadline, so a frozen-then-resumed
                    // phone keeps its sockets instead of retiring them on stale timestamps.
                    if (sessionReady && now - lastHostActivity > HOST_SILENCE_NANOS) {
                        // Releasing a host interface does not necessarily detach the accessory.
                        // Retire all internet sockets while waiting for the next explicit RESET.
                        streams.keys.toList().forEach { retire(it, false) }
                        abortPipes()
                        sessionReady = false
                        onSessionActive(false)
                    }
                }
            } catch (error: Exception) { stop(error.message ?: "USB bridge failed") }
            finally {
                streams.values.forEach { runCatching { it.socket.close() } }
                streams.clear()
                abortPipes()
                selector.close()
            }
        }, "aoa-sockets").apply { isDaemon = true; start() }
    }

    private fun worker(name: String, body: () -> Unit): Thread = Thread({
        try { body() } catch (error: Exception) { stop(error.message ?: "USB disconnected") }
    }, name).apply { isDaemon = true; start() }

    private fun handle(frame: AoaFrame) {
        lastHostActivity = System.nanoTime()
        if (frame.type == AoaFrame.RESET) {
            streams.keys.toList().forEach { retire(it, false) }
            synchronized(relaySendLock) {
                abortPipes() // before RESET_OK is queued: no aborted pipe can enqueue after it
                lastId = 0
                sessionReady = true
                onSessionActive(true)
                send(AoaFrame(AoaFrame.RESET_OK, 0, payload = frame.payload))
            }
            return
        }
        if (!sessionReady) return
        if (frame.type == AoaFrame.PING) { send(AoaFrame(AoaFrame.PONG, 0)); return }
        if (frame.type == AoaFrame.RESET_OK || frame.type == AoaFrame.PONG) throw IOException("unexpected session control")
        if (frame.type == AoaFrame.OPEN) {
            if (frame.streamId <= lastId) throw IOException("reused AOA stream")
            lastId = frame.streamId
            if (streams.size + pipes.size >= 256) { send(AoaFrame(AoaFrame.CLOSE, frame.streamId)); return }
            val socket = SocketChannel.open()
            val stream = Stream(frame.streamId, socket)
            streams[stream.id] = stream
            try {
                socket.configureBlocking(false)
                val port = when (frame.service) {
                    AoaFrame.RELAY -> relayPort
                    AoaFrame.PAIRING -> pairingPort
                    else -> throw IOException("invalid service")
                }
                val connected = socket.connect(InetSocketAddress("127.0.0.1", port))
                socket.register(selector, if (connected) 0 else SelectionKey.OP_CONNECT, stream)
                if (connected) opened(stream)
            } catch (_: IOException) { retire(stream.id, true) }
            return
        }
        if (frame.streamId > lastId) throw IOException("unknown AOA stream")
        val stream = streams[frame.streamId] ?: return // late frames for closed streams
        when (frame.type) {
            AoaFrame.CLOSE -> {
                // Explicit DBAM abort is different from FIN (a valid TCP half-close).
                runCatching { stream.socket.setOption(java.net.StandardSocketOptions.SO_LINGER, 0) }
                retire(stream.id, false)
            }
            AoaFrame.OPEN_OK -> throw IOException("unexpected OPEN_OK")
            AoaFrame.DATA -> {
                if (!stream.connected || stream.remoteFin || frame.payload.size > stream.receiveCredit)
                    throw IOException("DATA outside receive window")
                stream.receiveCredit -= frame.payload.size
                stream.receivedBytes += frame.payload.size
                stream.writes.add(ByteBuffer.wrap(frame.payload))
                interests(stream)
            }
            AoaFrame.WINDOW -> {
                val consumed = frame.credit()
                if (!stream.connected || consumed > stream.sentBytes) throw IOException("credit inflation")
                if (consumed <= stream.peerConsumedBytes) return // duplicate or older refresh
                stream.peerConsumedBytes = consumed
                stream.sendCredit = AoaFrame.INITIAL_CREDIT - (stream.sentBytes - consumed).toInt()
                interests(stream)
            }
            AoaFrame.FIN -> {
                if (!stream.connected || stream.remoteFin) throw IOException("unexpected FIN")
                stream.remoteFin = true
                drainFin(stream)
            }
        }
    }

    /** Reader thread. Serves in-memory RELAY streams directly; false queues the frame for the
     * selector (session control, loopback/pairing streams, and frames of an unready session). */
    private fun routeOnReader(frame: AoaFrame): Boolean {
        if (frame.type == AoaFrame.RESET) {
            readerLastId = 0
            selectorIds.clear()
            abortPipes() // the selector aborts again under relaySendLock before RESET_OK
            return false
        }
        if (frame.streamId == 0 || !sessionReady) return false
        if (frame.type == AoaFrame.OPEN) {
            if (frame.streamId <= readerLastId) throw IOException("reused AOA stream")
            readerLastId = frame.streamId
            val acceptor = relayAcceptor
            if (frame.service != AoaFrame.RELAY || acceptor == null) { selectorIds += frame.streamId; return false }
            openPipe(frame.streamId, acceptor)
            return true
        }
        pipes[frame.streamId]?.let { handlePipe(it, frame); return true }
        if (frame.streamId in selectorIds) return false
        if (frame.streamId > readerLastId) throw IOException("unknown AOA stream")
        return true // late frame of a finished in-memory stream; the selector would reject its ID
    }

    private fun openPipe(id: Int, acceptor: (java.net.Socket) -> Boolean) {
        if (streams.size + pipes.size >= 256) { send(AoaFrame(AoaFrame.CLOSE, id)); return }
        lateinit var pipe: AoaPipeSocket
        pipe = AoaPipeSocket(id, { sendFromRelay(pipe, it) }) { closed ->
            if (closed.isFinished) pipes.remove(closed.streamId, closed)
        }
        pipes[id] = pipe
        if (acceptor(pipe)) send(AoaFrame(AoaFrame.OPEN_OK, id))
        else { pipes.remove(id, pipe); pipe.abort(); send(AoaFrame(AoaFrame.CLOSE, id)) }
    }

    private fun handlePipe(pipe: AoaPipeSocket, frame: AoaFrame) {
        when (frame.type) {
            AoaFrame.CLOSE -> { pipes.remove(pipe.streamId, pipe); pipe.abort() }
            AoaFrame.OPEN_OK -> throw IOException("unexpected OPEN_OK")
            // Data for a relay that already closed aborts, as writing to a closed socket would.
            AoaFrame.DATA -> if (!pipe.deliver(frame.payload)) {
                pipes.remove(pipe.streamId, pipe); pipe.abort(); send(AoaFrame(AoaFrame.CLOSE, pipe.streamId))
            }
            AoaFrame.WINDOW -> pipe.credit(frame.credit())
            AoaFrame.FIN -> if (pipe.remoteFinished()) pipes.remove(pipe.streamId, pipe)
            AoaFrame.OPEN -> throw IOException("reused AOA stream")
        }
    }

    private fun abortPipes() {
        pipes.values.forEach { it.abort() }
        pipes.clear()
    }

    /** Relay worker threads: enqueue below the high water, leaving the rest for control frames. */
    private fun sendFromRelay(pipe: AoaPipeSocket, bytes: ByteArray) {
        while (true) {
            if (stopped.get()) throw IOException("USB disconnected")
            synchronized(relaySendLock) {
                if (pipe.isAborted) throw IOException("Socket closed")
                if (outgoing.size < dataHighWater && outgoing.offer(bytes)) return
            }
            // shortcut: bounded wait instead of an exact wakeup protocol; the writer notifies on drain.
            synchronized(backlog) { if (outgoing.size >= dataHighWater) backlog.wait(20) }
        }
    }

    private fun opened(stream: Stream) {
        stream.connected = true
        send(AoaFrame(AoaFrame.OPEN_OK, stream.id))
        interests(stream)
    }

    private fun readLocal(stream: Stream) {
        val buffer = socketReadBuffer
        buffer.clear()
        buffer.limit(minOf(buffer.capacity(), stream.sendCredit))
        val count = stream.socket.read(buffer)
        if (count < 0) {
            stream.localFin = true
            send(AoaFrame(AoaFrame.FIN, stream.id))
            drainFin(stream)
        } else if (count > 0) {
            stream.sendCredit -= count
            stream.sentBytes += count
            stream.lastSent = System.nanoTime()
            stream.idleReported = false
            sendEncoded(AoaFrame.encodeData(stream.id, buffer.array(), 0, count)) // one copy, not two
        }
        interests(stream)
    }

    private fun writeLocal(stream: Stream) {
        var consumed = 0
        while (stream.writes.isNotEmpty()) {
            val buffer = stream.writes.first
            val count = stream.socket.write(buffer)
            consumed += count
            if (!buffer.hasRemaining()) stream.writes.removeFirst()
            if (count == 0) break
        }
        if (consumed > 0) {
            stream.receiveCredit += consumed
            stream.consumedBytes += consumed
            if (stream.windowUpdate.consumed(stream.consumedBytes,System.nanoTime())) sendWindow(stream)
            else if (stream.windowUpdate.deadlineNanos != null) windowPending += stream
        }
        drainFin(stream)
        interests(stream)
    }

    private fun sendWindow(stream: Stream) {
        send(AoaFrame.window(stream.id,stream.consumedBytes))
        stream.windowUpdate.sent(stream.consumedBytes)
        windowPending -= stream
    }

    /** One selector deadline for all streams; no per-packet timer or idle polling added. */
    private fun flushWindowsAndWait(now: Long): Long {
        var waitMillis = ((lastHousekeeping + HOUSEKEEPING_NANOS - now + 999_999) / 1_000_000).coerceIn(1, 1000)
        for (stream in windowPending.toList()) {
            if (outgoing.remainingCapacity() == 0) break // Writer wakes us when a slot opens.
            if (stream.windowUpdate.isDue(now)) sendWindow(stream)
            stream.windowUpdate.deadlineNanos?.let { due ->
                waitMillis = minOf(waitMillis,((due-now+999_999)/1_000_000).coerceAtLeast(1))
            }
        }
        return waitMillis
    }

    /** Re-evaluates only streams the global backlog paused, and only once that limit lifts. */
    private fun releaseBacklogBlocked() {
        if (readBlocked.isNotEmpty() && outgoing.size < dataHighWater) readBlocked.toList().forEach(::interests)
        if (writeBlocked.isNotEmpty() && outgoing.remainingCapacity() > 0) writeBlocked.toList().forEach(::interests)
    }

    private fun drainFin(stream: Stream) {
        if (stream.remoteFin && stream.writes.isEmpty() && !stream.outputShutdown) {
            stream.socket.shutdownOutput()
            stream.outputShutdown = true
        }
        if (stream.localFin && stream.outputShutdown) retire(stream.id, false)
    }

    private fun interests(stream: Stream) {
        val key = stream.socket.keyFor(selector) ?: return
        if (!key.isValid) return
        readBlocked -= stream
        writeBlocked -= stream
        val readsOpen = outgoing.size < dataHighWater
        val writesOpen = outgoing.remainingCapacity() > 0
        if (!stream.connected) {
            key.interestOps(if (readsOpen) SelectionKey.OP_CONNECT else 0)
            if (!readsOpen) readBlocked += stream
            return
        }
        val wantsRead = !stream.localFin && stream.sendCredit > 0
        val wantsWrite = stream.writes.isNotEmpty()
        var ops = 0
        if (wantsRead && readsOpen) ops = ops or SelectionKey.OP_READ
        if (wantsWrite && writesOpen) ops = ops or SelectionKey.OP_WRITE
        key.interestOps(ops)
        if (wantsRead && !readsOpen) readBlocked += stream
        if (wantsWrite && !writesOpen) writeBlocked += stream
    }

    private fun retire(id: Int, notify: Boolean) {
        val stream = streams.remove(id) ?: return
        windowPending -= stream
        readBlocked -= stream
        writeBlocked -= stream
        stream.socket.close()
        if (notify) send(AoaFrame(AoaFrame.CLOSE, id))
    }

    private fun send(frame: AoaFrame) = sendEncoded(frame.encode())

    private fun sendEncoded(bytes: ByteArray) {
        if (!stopped.get() && !outgoing.offer(bytes)) throw IOException("USB writer queue exceeded")
    }

    override fun close() = stop("USB disconnected")

    private companion object {
        const val HOUSEKEEPING_NANOS = 1_000_000_000L
        // Longer than ReliableUsbState.NO_PROGRESS_MS so the reliable channel decides first.
        const val HOST_SILENCE_NANOS = (ReliableUsbState.NO_PROGRESS_MS + 10_000) * 1_000_000
    }

    internal fun transportFailed(reason: String) {
        if (!stopped.get()) reportReadFailure()
        stop(reason)
    }

    private fun reportReadFailure() {
        if (readFailureReported.compareAndSet(false, true)) runCatching { onReadFailure(readProgress) }
    }

    private fun stop(reason: String) {
        if (!stopped.compareAndSet(false, true)) return
        runCatching { onSessionActive(false) }
        runCatching(closeTransport) // owning ParcelFileDescriptor wakes the blocking USB read/write
        reader?.interrupt()
        writer?.interrupt()
        selector.wakeup()
        if (!started.get()) selector.close()
        onClosed(reason)
    }
}
