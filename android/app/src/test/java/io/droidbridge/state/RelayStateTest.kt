package io.droidbridge.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RelayStateTest {
    @Test
    fun `cellular loss while running becomes blocked without stopping service`() {
        val initial = RelayState(
            relayStatus = RelayStatus.RUNNING,
            cellularStatus = CellularStatus.AVAILABLE,
            activeFlows = 4,
            uploadedBytes = 100,
            downloadedBytes = 200,
            lastError = null,
        )

        val result = initial.onCellularLost("network lost")

        assertEquals(RelayStatus.BLOCKED_CELLULAR, result.relayStatus)
        assertEquals(CellularStatus.UNAVAILABLE, result.cellularStatus)
        assertEquals(0, result.activeFlows)
        assertEquals("network lost", result.lastError)
    }

    @Test
    fun `start from stopped enters starting and requests cellular`() {
        val result = RelayState().onStartRequested()
        assertEquals(RelayStatus.STARTING, result.relayStatus)
        assertEquals(CellularStatus.REQUESTING, result.cellularStatus)
        assertNull(result.lastError)
    }

    @Test
    fun `start is ignored unless stopped or failed`() {
        for (status in listOf(RelayStatus.STARTING, RelayStatus.RUNNING, RelayStatus.BLOCKED_CELLULAR, RelayStatus.STOPPING)) {
            val state = RelayState(relayStatus = status)
            assertEquals(state, state.onStartRequested())
        }
        assertEquals(RelayStatus.STARTING, RelayState(relayStatus = RelayStatus.FAILED).onStartRequested().relayStatus)
    }

    @Test
    fun `cellular available while starting or blocked becomes running`() {
        for (status in listOf(RelayStatus.STARTING, RelayStatus.BLOCKED_CELLULAR)) {
            val result = RelayState(relayStatus = status).onCellularAvailable("Carrier")
            assertEquals(RelayStatus.RUNNING, result.relayStatus)
            assertEquals(CellularStatus.AVAILABLE, result.cellularStatus)
            assertEquals("Carrier", result.carrierName)
        }
    }

    @Test
    fun `stop from every state resets to stopped with zero flows`() {
        for (status in RelayStatus.entries) {
            val result = RelayState(relayStatus = status, activeFlows = 3, cellularStatus = CellularStatus.AVAILABLE).onStopped()
            assertEquals(RelayStatus.STOPPED, result.relayStatus)
            assertEquals(CellularStatus.UNAVAILABLE, result.cellularStatus)
            assertEquals(0, result.activeFlows)
        }
    }

    @Test
    fun `stop requested enters stopping and keeps counters`() {
        val result = RelayState(relayStatus = RelayStatus.RUNNING, uploadedBytes = 5).onStopRequested()
        assertEquals(RelayStatus.STOPPING, result.relayStatus)
        assertEquals(5, result.uploadedBytes)
    }

    @Test
    fun `flow count never goes below zero`() {
        val state = RelayState(activeFlows = 0).onFlowClosed()
        assertEquals(0, state.activeFlows)
        assertEquals(1, RelayState().onFlowOpened().activeFlows)
    }

    @Test
    fun `byte counters saturate instead of overflowing and reject negatives`() {
        val nearMax = RelayState(uploadedBytes = Long.MAX_VALUE - 1, downloadedBytes = Long.MAX_VALUE)
        val result = nearMax.onBytesTransferred(uploaded = 10, downloaded = 10)
        assertEquals(Long.MAX_VALUE, result.uploadedBytes)
        assertEquals(Long.MAX_VALUE, result.downloadedBytes)
        val negative = RelayState(uploadedBytes = 7).onBytesTransferred(uploaded = -5, downloaded = -1)
        assertEquals(7, negative.uploadedBytes)
        assertEquals(0, negative.downloadedBytes)
    }

    @Test
    fun `failure records error and stops`() {
        val result = RelayState(relayStatus = RelayStatus.RUNNING, activeFlows = 2).onFailed("bind failed")
        assertEquals(RelayStatus.FAILED, result.relayStatus)
        assertEquals("bind failed", result.lastError)
        assertEquals(0, result.activeFlows)
    }
}
