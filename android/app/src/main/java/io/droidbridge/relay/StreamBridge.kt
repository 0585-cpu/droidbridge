package io.droidbridge.relay

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext

/** An owned endpoint: graceful half-close and a full close that unblocks socket IO. */
class BridgeEnd(
    val name: String,
    val input: InputStream,
    val output: OutputStream,
    val halfCloseOutput: () -> Unit,
    val close: () -> Unit = {
        runCatching { input.close() }
        runCatching { output.close() }
    },
)

/**
 * Copies bytes in both directions with two 64 KiB buffers. When one direction reaches EOF, the opposite
 * output is half-closed and the other direction continues until its own EOF or inactivity timeout. A
 * connection is idle only when neither direction moves bytes for [idleMs]. A streamed response must
 * remain open even when the request direction is silent. Closing endpoints unblocks Android socket
 * reads and writes, which do not reliably respond to thread interruption alone.
 */
class StreamBridge(
    private val idleMs: Long = 5 * 60 * 1000,
    private val bufferSize: Int = 64 * 1024,
) {
    /** Returns (aToB, bToA) byte counts. `a` is the DBP client, `b` the remote cellular socket. */
    suspend fun copyBidirectional(a: BridgeEnd, b: BridgeEnd, traffic: RelayTrafficPolicy = RelayTrafficPolicy(), onTransfer: (Long,Long) -> Unit = {_,_->}): Pair<Long, Long> = withContext(Dispatchers.Default) {
        val aToB = AtomicLong()
        val bToA = AtomicLong()
        val lastActivity = AtomicLong(System.nanoTime())
        fun active() { lastActivity.set(System.nanoTime()) }
        fun closeBoth() { runCatching { a.close() }; runCatching { b.close() } }
        lateinit var jobAtoB: Job
        lateinit var jobBtoA: Job

        // Each direction stays on one socket worker for both its blocking read and write.
        // Returning to Default after every blocking operation adds per-chunk scheduler work.
        jobAtoB = launch(RelayDispatchers.socketReads) { copyLoop(a, b, aToB, traffic.profile.burstBytes, traffic::upload, ::active) { onTransfer(it,0) } }
        jobBtoA = launch(RelayDispatchers.socketReads) { copyLoop(b, a, bToA, traffic.profile.burstBytes, traffic::download, ::active) { onTransfer(0,it) } }

        val idleWatch = launch {
            while (isActive) {
                val remaining = idleMs * 1_000_000 - (System.nanoTime() - lastActivity.get())
                if (remaining <= 0) {
                    jobAtoB.cancel(); jobBtoA.cancel()
                    closeBoth()
                    break
                }
                delay((remaining / 1_000_000).coerceAtLeast(1))
            }
        }

        // EOF ends only one direction. Ongoing replies/uploads refresh the shared idle deadline.
        // Errors still close both descriptors, including reads that ignore interruption.
        jobAtoB.invokeOnCompletion { cause ->
            if (cause != null) closeBoth()
            else runCatching { b.halfCloseOutput() }.onFailure { closeBoth() }
        }
        jobBtoA.invokeOnCompletion { cause ->
            if (cause != null) closeBoth()
            else runCatching { a.halfCloseOutput() }.onFailure { closeBoth() }
        }

        try {
            jobAtoB.join()
            jobBtoA.join()
            aToB.get() to bToA.get()
        } finally {
            idleWatch.cancel()
            jobAtoB.cancel(); jobBtoA.cancel()
            closeBoth()
        }
    }

    private suspend fun copyLoop(from: BridgeEnd, to: BridgeEnd, counter: AtomicLong, burst: Int, shape: suspend (Int) -> Unit, active: () -> Unit, onTransfer: (Long) -> Unit) {
        val buffer = ByteArray(minOf(bufferSize,burst))
        try {
            while (true) {
                val read = runInterruptible(RelayDispatchers.socketReads) { from.input.read(buffer) }
                if (read < 0) break
                if (read > 0) {
                    active()
                    shape(read)
                    // Same thread as the read: a dispatcher hop per chunk costs two thread handoffs,
                    // and each copy direction already owns one blocking thread anyway.
                    runInterruptible { to.output.write(buffer, 0, read); to.output.flush() }
                    active()
                    counter.addAndGet(read.toLong())
                    onTransfer(read.toLong())
                }
            }
        } catch (error: IOException) {
            // Closing a descriptor during idle/cancellation can throw IOException rather than
            // InterruptedException. Preserve cancellation; real socket failures still abort both ends.
            currentCoroutineContext().ensureActive()
            throw error
        }
    }
}
