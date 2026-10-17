package io.droidbridge.relay

import kotlinx.coroutines.Dispatchers

/** Blocking data-plane operations never occupy the default IO pool used for control and opens.
 * At the declared 256 TCP + 256 UDP ceiling each flow has two readers and two writers at most.
 * These elastic, bounded views create threads on demand; timers use Default. UDP workers stay
 * on their IO view across queue/shaping suspensions to avoid per-datagram dispatcher switches.
 * Device acceptance must measure memory/throughput at high flow counts before raising defaults. */
internal object RelayDispatchers {
    val accepts = Dispatchers.IO.limitedParallelism(1)
    val controlReads = Dispatchers.IO.limitedParallelism(64)
    val controlWrites = Dispatchers.IO.limitedParallelism(16)
    val pendingReads = Dispatchers.IO.limitedParallelism(32)
    private const val MAX_COMBINED_FLOWS=512
    val socketReads=Dispatchers.IO.limitedParallelism(MAX_COMBINED_FLOWS*2)
    val socketWrites=Dispatchers.IO.limitedParallelism(MAX_COMBINED_FLOWS*2)
}
