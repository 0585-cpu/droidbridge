package io.droidbridge.relay

import io.droidbridge.network.SocketPolicyException
import io.droidbridge.protocol.DbpCodec
import io.droidbridge.protocol.DbpMessageType
import io.droidbridge.protocol.DbpPayload
import io.droidbridge.protocol.HealthStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

class RelayMetricsTest {
    @Test
    fun `packet counters accumulate without publishing until the next UI tick`() {
        val metrics = RelayMetrics(128) { "carrier" }
        val before = metrics.snapshot.value
        repeat(10_000) {
            metrics.addTransfer(1_200, 65_536)
            metrics.addUdpDrops(1)
        }
        assertSame(before, metrics.snapshot.value, "packets must not wake UI collectors")
        // Control-plane replies must still see live totals before the next UI refresh.
        val health = DbpCodec.decodePayload(DbpMessageType.HEALTH_RESPONSE, metrics.healthPayload(HealthStatus.READY)) as DbpPayload.Health
        assertEquals(12_000_000L, health.uploadedBytes)
        assertEquals(655_360_000L, health.downloadedBytes)
        assertEquals(10_000L, metrics.udpDrops())
        metrics.tick()
        assertEquals(12_000_000L, metrics.snapshot.value.uploadedBytes)
        assertEquals(655_360_000L, metrics.snapshot.value.downloadedBytes)
        assertEquals(10_000L, metrics.snapshot.value.udpDrops)
    }

    @Test
    fun `connection lifecycle and policy failures remain immediately visible`() {
        val metrics = RelayMetrics(128) { null }
        metrics.flowOpened()
        metrics.udpOpened()
        assertEquals(1, metrics.snapshot.value.activeFlows)
        assertEquals(1, metrics.snapshot.value.activeUdp)
        metrics.addTransfer(10, 20)
        metrics.flowClosed()
        metrics.udpClosed()
        assertEquals(0, metrics.snapshot.value.activeFlows)
        assertEquals(0, metrics.snapshot.value.activeUdp)
        assertEquals(20L, metrics.snapshot.value.downloadedBytes)
        val failure = SocketPolicyException()
        metrics.recordError(failure)
        assertEquals(failure.message, metrics.snapshot.value.policyError)
    }
}
