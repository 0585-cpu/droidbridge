package io.droidbridge.usb

import java.io.Closeable
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.ArrayDeque
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/** Bounded reliable byte channel. Only its writer touches rawOutput; ACK generation
 * never blocks the reader behind a bulk write. Closing releases the owned descriptor. */
class ReliableAccessoryChannel(
    private val rawInput: InputStream,
    private val rawOutput: OutputStream,
    private val closeTransport: () -> Unit,
    private val onClosed: (Long, String) -> Unit = { _, _ -> },
    private val onRetransmission: (Long) -> Unit = {},
    // A frozen phone resumes with an old write start; tolerate the same window as delivery.
    private val writeTimeoutMs: Long = ReliableUsbState.NO_PROGRESS_MS,
) : Closeable {
    private val monitor = Object()
    private val state = ReliableUsbState(null, now())
    private var failure: IOException? = null
    private var writeStarted: Long? = null
    private val watchdog = ScheduledThreadPoolExecutor(1) { work ->
        Thread(work, "aoa-reliable-deadline").apply { isDaemon = true }
    }.apply {
        removeOnCancelPolicy = true
        executeExistingDelayedTasksAfterShutdownPolicy = false
        setKeepAliveTime(1, TimeUnit.SECONDS)
        allowCoreThreadTimeOut(true)
    }
    private var deadlineTask: ScheduledFuture<*>? = null
    // The raw reader always drains ACKs independently of application backpressure.
    // Queue + current partial record share a 512 KiB byte limit (also <=64 queued records).
    private val decoder = ReliableUsbDecoder()
    private val received = ArrayDeque<ByteArray>()
    private var bufferedBytes = 0
    private var current = ByteArray(0)
    private var offset = 0
    private val readerBuffer = ByteArray(16384)

    val input: InputStream = object : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one,0,1) < 0) -1 else one[0].toInt() and 255
        }
        override fun read(b: ByteArray, off: Int, len: Int): Int {
            require(off >= 0 && len >= 0 && off <= b.size-len)
            if (len == 0) return 0
            try {
                synchronized(monitor) {
                    while (offset == current.size) {
                        failure?.let { throw it }
                        if (received.isNotEmpty()) { current = received.removeFirst(); offset = 0; break }
                        monitor.wait()
                    }
                    failure?.let { throw it }
                    val count = minOf(len,current.size-offset)
                    current.copyInto(b,off,offset,offset+count)
                    offset += count
                    bufferedBytes -= count
                    return count
                }
            } catch (error: Exception) { throw stop(error) }
        }
        override fun close() = this@ReliableAccessoryChannel.close()
    }

    val output: OutputStream = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()))
        override fun write(b: ByteArray, off: Int, len: Int) {
            require(off >= 0 && len >= 0 && off <= b.size-len)
            try {
                var pos = off
                while (pos < off+len) {
                    val end = minOf(pos+ReliableUsbRecord.MAX_PAYLOAD,off+len)
                    synchronized(monitor) {
                        while (true) {
                            failure?.let { throw it }
                            if (state.offer(b,pos,end-pos,now())) {
                                armDeadlineLocked()
                                break
                            }
                            monitor.wait()
                        }
                        monitor.notifyAll()
                    }
                    pos = end
                }
            } catch (error: Exception) { throw stop(error) }
        }
        override fun close() = this@ReliableAccessoryChannel.close()
    }

    init {
        Thread({
            try {
                while (true) {
                    synchronized(monitor) { failure?.let { throw it } }
                    val count = rawInput.read(readerBuffer)
                    if (count < 0) throw IOException("reliable USB disconnected")
                    val records = decoder.append(readerBuffer,0,count)
                    synchronized(monitor) {
                        failure?.let { throw it }
                        records.forEach { record ->
                            val capacity = received.size < 64 && record.payload.size <= 512*1024-bufferedBytes
                            state.receive(record,now(),acceptPayload=capacity)?.let {
                                received.addLast(it); bufferedBytes += it.size
                            }
                        }
                        if (records.isNotEmpty()) monitor.notifyAll()
                    }
                }
            } catch (error: Exception) { stop(error) }
        }, "aoa-reliable-reader").apply { isDaemon = true; start() }
        Thread({
            var reportedRetries = 0L
            var lastReport = 0L
            try {
                while (true) {
                    val record = synchronized(monitor) {
                        failure?.let { throw it }
                        state.next(now()).also {
                            if (it == null) {
                                val wake = state.nextWakeAt(now())
                                if (wake == null) monitor.wait()
                                else monitor.wait((wake-now()).coerceAtLeast(1))
                            }
                        }
                    }
                    val retries = synchronized(monitor) { state.retransmissions }
                    if (retries > reportedRetries && now()-lastReport >= 5000) {
                        reportedRetries = retries; lastReport = now()
                        runCatching { onRetransmission(retries) }
                    }
                    if (record != null) {
                        val bytes = record.encode()
                        synchronized(monitor) {
                            failure?.let { throw it }
                            writeStarted = now()
                            armDeadlineLocked()
                        }
                        var pos = 0
                        while (pos < bytes.size) {
                            // Keep each descriptor write within the accessory's 16 KiB limit.
                            val count = minOf(16384, bytes.size-pos)
                            rawOutput.write(bytes,pos,count); pos += count
                        }
                        synchronized(monitor) { writeStarted = null }
                    }
                }
            } catch (error: Exception) { stop(error) }
        }, "aoa-reliable-writer").apply { isDaemon = true; start() }
    }

    /** Called under monitor. Keep one timer for the earliest observed deadline. Progress may move
     * the deadline later; the timer then rechecks and rearms once, without per-packet wakeups. */
    private fun armDeadlineLocked() {
        if (failure != null || deadlineTask != null) return
        val delivery = state.deadlineAt()
        val write = writeStarted?.plus(writeTimeoutMs)
        val deadline = when {
            delivery == null -> write
            write == null -> delivery
            else -> minOf(delivery, write)
        } ?: return
        deadlineTask = watchdog.schedule(::checkDeadlines, (deadline-now()).coerceAtLeast(1), TimeUnit.MILLISECONDS)
    }

    private fun checkDeadlines() {
        try {
            synchronized(monitor) {
                if (failure != null) return
                deadlineTask = null
                val time = now()
                state.checkDeadline(time)
                if (writeStarted?.let { time-it >= writeTimeoutMs } == true) throw IOException("USB bulk write timed out")
                armDeadlineLocked()
            }
        } catch (error: Exception) { stop(error) }
    }

    override fun close() { stop(IOException("reliable USB closed")) }

    private fun stop(error: Exception): IOException {
        var first = false
        var retries = 0L
        val reason = synchronized(monitor) {
            if (failure == null) {
                failure = error as? IOException ?: IOException("reliable USB stopped",error)
                first = true; retries = state.retransmissions
                deadlineTask?.cancel(false); deadlineTask = null
                monitor.notifyAll()
            }
            failure!!
        }
        if (first) {
            watchdog.shutdown()
            // Closing an owned FD can wake or wait for IO; never do it under the monitor.
            runCatching { closeTransport() }
            runCatching { onClosed(retries,reason.message ?: "USB stopped") }
        }
        return reason
    }
    private fun now() = System.nanoTime()/1_000_000
}
