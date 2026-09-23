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
    val activeUdp: Int = 0,
    val udpDrops: Long = 0,
    val policyError: String? = null,
    val uploadBytesPerSecond: Long = 0,
    val downloadBytesPerSecond: Long = 0,
)

/** Atomic counters only. Never records destinations or payload. */
class RelayMetrics(private val maximumFlows: Int, private val carrierName: () -> String?) {
    private val active = AtomicInteger(0)
    private val udp = AtomicInteger(0)
    private val drops = AtomicLong(0)
    @Volatile private var policyError: String? = null
    private val uploaded = AtomicLong(0)
    private val downloaded = AtomicLong(0)
    private var sampledAt=System.nanoTime()
    private var sampledUp=0L
    private var sampledDown=0L
    private var upRate=0L
    private var downRate=0L
    private val _snapshot = MutableStateFlow(RelayMetricsSnapshot(0, maximumFlows, 0, 0))
    val snapshot: StateFlow<RelayMetricsSnapshot> = _snapshot

    fun activeUdp(): Int = udp.get()
    fun udpDrops(): Long = drops.get()
    fun udpOpened() { udp.incrementAndGet(); publish() }
    fun udpClosed() { udp.decrementAndGet(); publish() }
    fun addUdpDrops(count: Long) { if(count>0) drops.addAndGet(count); publish() }
    fun recordError(error: Exception) { if(error is io.droidbridge.network.SocketPolicyException) { policyError=error.message; publish() } }
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

    fun tick() = publish()
    @Synchronized private fun publish() {
        val now=System.nanoTime()
        val elapsed=now-sampledAt
        if(elapsed>=1_000_000_000L) {
            upRate=((uploaded.get()-sampledUp)*1e9/elapsed).toLong()
            downRate=((downloaded.get()-sampledDown)*1e9/elapsed).toLong()
            sampledUp=uploaded.get(); sampledDown=downloaded.get(); sampledAt=now
        }
        _snapshot.value = RelayMetricsSnapshot(active.get(), maximumFlows, uploaded.get(), downloaded.get(), udp.get(), drops.get(),policyError,upRate,downRate)
    }
}
