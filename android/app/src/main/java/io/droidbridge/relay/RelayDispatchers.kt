package io.droidbridge.relay

import kotlinx.coroutines.Dispatchers

/** Blocking data-plane operations never occupy the default IO pool used for control and opens.
 * At the declared 256 TCP + 256 UDP ceiling each flow has two readers and two writers at most.
 * These elastic, bounded views create threads on demand; timers/queues/shaping use Default.
 * Device acceptance must measure memory/throughput at high flow counts before raising defaults. */
internal object RelayDispatchers {
    private const val MAX_COMBINED_FLOWS=512
    val socketReads=Dispatchers.IO.limitedParallelism(MAX_COMBINED_FLOWS*2)
    val socketWrites=Dispatchers.IO.limitedParallelism(MAX_COMBINED_FLOWS*2)
}
