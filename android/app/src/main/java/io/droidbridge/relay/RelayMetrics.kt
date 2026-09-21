package io.droidbridge.relay

import io.droidbridge.protocol.DbpCodec
import io.droidbridge.protocol.DbpPayload
import io.droidbridge.protocol.HealthStatus
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

data class RelayMetricsSnapshot(
    val activeFlows: Int,
    val maximumFlows: Int,
    val uploadedBytes: Long,
    val downloadedBytes: Long,
)

/** Atomic counters only. Never records destinations or payload. */
class RelayMetrics(private val maximumFlows: Int, private val carrierName: () -> String?) {
    private val active = AtomicInteger(0)
    private val uploaded = AtomicLong(0)
    private val downloaded = AtomicLong(0)
    private val _snapshot = MutableStateFlow(RelayMetricsSnapshot(0, maximumFlows, 0, 0))
    val snapshot: StateFlow<RelayMetricsSnapshot> = _snapshot

    fun flowOpened() { active.incrementAndGet(); publish() }
    fun flowClosed() { active.decrementAndGet(); publish() }
    fun addTransfer(up: Long, down: Long) {
        if (up > 0) uploaded.addAndGet(up)
        if (down > 0) downloaded.addAndGet(down)
        publish()
    }

    /** Builds the canonical HEALTH_RESPONSE payload; rejects impossible internal values before encoding. */
    fun healthPayload(status: HealthStatus): ByteArray {
        val name = carrierName()?.take(63) ?: ""
        return DbpCodec.encodeHealth(
            DbpPayload.Health(status, active.get(), maximumFlows, uploaded.get(), downloaded.get(), name),
        )
    }

    private fun publish() {
        _snapshot.value = RelayMetricsSnapshot(active.get(), maximumFlows, uploaded.get(), downloaded.get())
    }
}
