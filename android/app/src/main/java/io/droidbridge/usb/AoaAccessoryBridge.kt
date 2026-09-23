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
    private val onClosed: (String) -> Unit = {},
) : Closeable {
    private class Stream(val id: Int, val socket: SocketChannel) {
        var connected = false
        var localFin = false
        var remoteFin = false
        var outputShutdown = false
        var sendCredit = AoaFrame.INITIAL_CREDIT
        var receiveCredit = AoaFrame.INITIAL_CREDIT
        val writes = ArrayDeque<ByteBuffer>()
        val deadline = System.nanoTime() + 5_000_000_000L
    }
    private val selector = Selector.open()
    private val incoming = ArrayBlockingQueue<AoaFrame>(1024)
    private val outgoing = ArrayBlockingQueue<ByteArray>(1024)
    private val stopped = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    // Only the selector thread accesses streams and lastId.
    private val streams = mutableMapOf<Int, Stream>()
    private var lastId = 0
    private var sessionReady = false
    private var lastHostActivity = System.nanoTime()
    private var reader: Thread? = null
    private var writer: Thread? = null

    fun start() {
        check(started.compareAndSet(false, true) && !stopped.get())
        writer = worker("aoa-writer") {
            while (!stopped.get()) {
                val bytes = outgoing.take()
                // Keep every USB write within the documented Android accessory read buffer.
                var offset = 0
                while (offset < bytes.size) {
                    val count = minOf(AoaFrame.MAX_PAYLOAD, bytes.size - offset)
                    output.write(bytes, offset, count)
                    offset += count
                }
            }
        }
        reader = worker("aoa-reader") {
            while (!stopped.get()) {
                val frame = AoaFrame.read(input) ?: throw IOException("USB disconnected")
                if (!incoming.offer(frame)) throw IOException("USB receive queue exceeded")
                selector.wakeup()
            }
        }
        Thread({
            try {
                while (!stopped.get()) {
                    selector.select(250)
                    // Bound each batch so a busy USB peer cannot starve socket IO.
                    repeat(1024) { incoming.poll()?.let(::handle) }
                    val selected = selector.selectedKeys().iterator()
                    while (selected.hasNext()) {
                        val key = selected.next()
                        selected.remove()
                        if (!key.isValid) continue
                        val stream = key.attachment() as Stream
                        try {
                            if (key.isConnectable && stream.socket.finishConnect()) opened(stream)
                            if (key.isValid && key.isWritable) writeLocal(stream)
                            if (key.isValid && key.isReadable) readLocal(stream)
                        } catch (_: IOException) { retire(stream.id, true) }
                    }
                    streams.values.filter { !it.connected && System.nanoTime() > it.deadline }
                        .forEach { retire(it.id, true) }
                    if (sessionReady && System.nanoTime() - lastHostActivity > 10_000_000_000L) {
                        // Releasing a host interface does not necessarily detach the accessory.
                        // Retire all internet sockets while waiting for the next explicit RESET.
                        streams.keys.toList().forEach { retire(it, false) }
                        sessionReady = false
                    }
                }
            } catch (error: Exception) { stop(error.message ?: "USB bridge failed") }
            finally {
                streams.values.forEach { runCatching { it.socket.close() } }
                streams.clear()
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
            lastId = 0
            sessionReady = true
            send(AoaFrame(AoaFrame.RESET_OK, 0, payload = frame.payload))
            return
        }
        if (!sessionReady) return
        if (frame.type == AoaFrame.PING) { send(AoaFrame(AoaFrame.PONG, 0)); return }
        if (frame.type == AoaFrame.RESET_OK || frame.type == AoaFrame.PONG) throw IOException("unexpected session control")
        if (frame.type == AoaFrame.OPEN) {
            if (frame.streamId <= lastId) throw IOException("reused AOA stream")
            lastId = frame.streamId
            if (streams.size >= 256) { send(AoaFrame(AoaFrame.CLOSE, frame.streamId)); return }
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
            AoaFrame.CLOSE -> retire(stream.id, false)
            AoaFrame.OPEN_OK -> throw IOException("unexpected OPEN_OK")
            AoaFrame.DATA -> {
                if (!stream.connected || stream.remoteFin || frame.payload.size > stream.receiveCredit)
                    throw IOException("DATA outside receive window")
                stream.receiveCredit -= frame.payload.size
                stream.writes.add(ByteBuffer.wrap(frame.payload))
                interests(stream)
            }
            AoaFrame.WINDOW -> {
                if (!stream.connected || stream.sendCredit > AoaFrame.INITIAL_CREDIT - frame.credit())
                    throw IOException("credit inflation")
                stream.sendCredit += frame.credit()
                interests(stream)
            }
            AoaFrame.FIN -> {
                if (!stream.connected || stream.remoteFin) throw IOException("unexpected FIN")
                stream.remoteFin = true
                drainFin(stream)
            }
        }
    }

    private fun opened(stream: Stream) {
        stream.connected = true
        send(AoaFrame(AoaFrame.OPEN_OK, stream.id))
        interests(stream)
    }

    private fun readLocal(stream: Stream) {
        val buffer = ByteBuffer.allocate(minOf(AoaFrame.MAX_PAYLOAD, stream.sendCredit))
        val count = stream.socket.read(buffer)
        if (count < 0) {
            stream.localFin = true
            send(AoaFrame(AoaFrame.FIN, stream.id))
            drainFin(stream)
        } else if (count > 0) {
            stream.sendCredit -= count
            send(AoaFrame(AoaFrame.DATA, stream.id, payload = buffer.array().copyOf(count)))
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
            send(AoaFrame.window(stream.id, consumed))
        }
        drainFin(stream)
        interests(stream)
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
        if (!key.isValid || !stream.connected) return
        var ops = 0
        if (!stream.localFin && stream.sendCredit > 0) ops = ops or SelectionKey.OP_READ
        if (stream.writes.isNotEmpty()) ops = ops or SelectionKey.OP_WRITE
        key.interestOps(ops)
    }

    private fun retire(id: Int, notify: Boolean) {
        val stream = streams.remove(id) ?: return
        stream.socket.close()
        if (notify) send(AoaFrame(AoaFrame.CLOSE, id))
    }

    private fun send(frame: AoaFrame) {
        if (!stopped.get() && !outgoing.offer(frame.encode())) throw IOException("USB writer queue exceeded")
    }

    override fun close() = stop("USB disconnected")

    private fun stop(reason: String) {
        if (!stopped.compareAndSet(false, true)) return
        runCatching(closeTransport) // owning ParcelFileDescriptor wakes the blocking USB read/write
        reader?.interrupt()
        writer?.interrupt()
        selector.wakeup()
        if (!started.get()) selector.close()
        onClosed(reason)
    }
}
