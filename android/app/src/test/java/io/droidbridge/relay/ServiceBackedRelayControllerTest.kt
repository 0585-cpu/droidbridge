package io.droidbridge.relay

import io.droidbridge.state.RelayState
import io.droidbridge.ui.RelayController
import kotlinx.coroutines.flow.MutableStateFlow
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertSame

private class RecordingRelay(val events: MutableList<String>) : RelayController {
    override val state = MutableStateFlow(RelayState())
    override val metrics = MutableStateFlow(RelayMetricsSnapshot(0, 128, 0, 0))
    override fun start() { events += "relay.start" }
    override fun stop() { events += "relay.stop" }
    override fun forgetPeer() { events += "relay.forget" }
}

class ServiceBackedRelayControllerTest {
    private val events = mutableListOf<String>()
    private val relay = RecordingRelay(events)
    private val controller = ServiceBackedRelayController(
        relay,
        startService = { events += "service.start" },
        stopService = { events += "service.stop" },
    )

    /** Only a running foreground service keeps the relay alive once the app is closed or the screen is off. */
    @Test
    fun `start goes through the foreground service, never straight to the relay`() {
        controller.start()
        assertEquals(listOf("service.start"), events)
    }

    @Test
    fun `stop halts the relay at once and releases the foreground service`() {
        controller.stop()
        assertEquals(listOf("relay.stop", "service.stop"), events)
    }

    /** The secret must never be deleted while the relay is still serving with it. */
    @Test
    fun `forgetting the peer stops serving before the secret is cleared`() {
        controller.forgetPeer()
        assertEquals(listOf("relay.stop", "service.stop", "relay.forget"), events)
    }

    @Test
    fun `the UI observes the one shared relay`() {
        assertSame(relay.state, controller.state)
        assertSame(relay.metrics, controller.metrics)
    }
}
