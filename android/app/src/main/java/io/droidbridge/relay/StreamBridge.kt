package io.droidbridge.relay

import java.io.InputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** One end of a bridged connection: streams plus a half-close (shutdownOutput) hook. */
class BridgeEnd(
    val name: String,
    val input: InputStream,
    val output: OutputStream,
    val halfCloseOutput: () -> Unit,
)

/**
 * Copies bytes in both directions with two 64 KiB buffers. When one direction reaches EOF, the opposite
 * output is half-closed and the other direction is given [graceMs] to drain before it is cancelled. A
 * direction that moves no bytes for [idleMs] times out on its own; the timeout is per read, so activity
 * in that direction keeps it alive.
 */
class StreamBridge(
    private val idleMs: Long = 5 * 60 * 1000,
    private val graceMs: Long = 10 * 1000,
    private val bufferSize: Int = 64 * 1024,
) {
    /** Returns (aToB, bToA) byte counts. `a` is the DBP client, `b` the remote cellular socket. */
    suspend fun copyBidirectional(a: BridgeEnd, b: BridgeEnd, traffic: RelayTrafficPolicy = RelayTrafficPolicy(), onTransfer: (Long,Long) -> Unit = {_,_->}): Pair<Long, Long> = withContext(Dispatchers.Default) {
        val aToB = AtomicLong()
        val bToA = AtomicLong()
        lateinit var jobAtoB: Job
        lateinit var jobBtoA: Job

        jobAtoB = launch { copyLoop(a, b, aToB, traffic.profile.burstBytes, traffic::upload) { onTransfer(it,0) } }
        jobBtoA = launch { copyLoop(b, a, bToA, traffic.profile.burstBytes, traffic::download) { onTransfer(0,it) } }

        // A grace watcher runs in its own coroutine (never inside a copy job) so the two copies never
        // wait on each other — mutual join would deadlock.
        jobAtoB.invokeOnCompletion { runCatching { b.halfCloseOutput() }; launch { graceThenCancel(jobBtoA) } }
        jobBtoA.invokeOnCompletion { runCatching { a.halfCloseOutput() }; launch { graceThenCancel(jobAtoB) } }

        jobAtoB.join()
        jobBtoA.join()
        aToB.get() to bToA.get()
    }

    private suspend fun copyLoop(from: BridgeEnd, to: BridgeEnd, counter: AtomicLong, burst: Int, shape: suspend (Int) -> Unit, onTransfer: (Long) -> Unit) {
        val buffer = ByteArray(minOf(bufferSize,burst))
        try {
            while (true) {
                // runInterruptible lets the idle withTimeout actually interrupt a blocked read()
                val read = withTimeout(idleMs) { runInterruptible(RelayDispatchers.socketReads) { from.input.read(buffer) } }
                if (read < 0) break
                if (read > 0) {
                    shape(read)
                    runInterruptible(RelayDispatchers.socketWrites) { to.output.write(buffer, 0, read); to.output.flush() }
                    counter.addAndGet(read.toLong())
                    onTransfer(read.toLong())
                }
            }
        } catch (e: TimeoutCancellationException) {
            // idle timeout on this direction
        } catch (e: java.io.IOException) {
            // peer closed mid-stream
        }
    }

    private suspend fun graceThenCancel(sibling: Job) {
        try {
            withTimeout(graceMs) { sibling.join() }
        } catch (e: TimeoutCancellationException) {
            sibling.cancel()
        }
    }
}
