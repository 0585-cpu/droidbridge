package io.droidbridge.relay

import io.droidbridge.ui.RelayController

/**
 * The UI's view of the one process-wide relay. Starting goes through [RelayForegroundService]:
 * a relay run from the screen alone dies when the app is closed and is frozen or cut off from the
 * network when the screen turns off, because Android then treats the app as a background process.
 * Stopping takes effect at once and then releases the service.
 */
class ServiceBackedRelayController(
    private val relay: RelayController,
    private val startService: () -> Unit,
    private val stopService: () -> Unit,
) : RelayController {
    override val state = relay.state
    override val metrics = relay.metrics
    override val profile = relay.profile
    override val capabilities = relay.capabilities
    override fun updateProfile(profile: TrafficProfile): Boolean = relay.updateProfile(profile)

    override fun start() = startService()

    override fun stop() {
        relay.stop()
        stopService()
    }

    /** Stops synchronously first: the secret must never be deleted while the relay is serving with it. */
    override fun forgetPeer() {
        stop()
        relay.forgetPeer()
    }
}
