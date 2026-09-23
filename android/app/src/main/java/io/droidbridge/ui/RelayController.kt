package io.droidbridge.ui

import io.droidbridge.relay.RelayMetricsSnapshot
import io.droidbridge.state.RelayState
import kotlinx.coroutines.flow.StateFlow

/** What the UI drives: the relay lifecycle plus the single-peer registration. */
interface RelayController {
    val state: StateFlow<RelayState>
    val metrics: StateFlow<RelayMetricsSnapshot>
    val profile: StateFlow<io.droidbridge.relay.TrafficProfile> get() = RelayDefaults.profile
    val capabilities: StateFlow<Long> get() = RelayDefaults.capabilities
    fun updateProfile(profile: io.droidbridge.relay.TrafficProfile): Boolean = false
    fun start()
    fun stop()
    fun forgetPeer()
}

/** Pairing surface for the UI. */
interface PairingFacade {
    val state: StateFlow<io.droidbridge.pairing.PairingUiState>
    fun beginPairing()
    fun approve()
    fun reject()
    fun cancel()
}

private object RelayDefaults {
    val profile= kotlinx.coroutines.flow.MutableStateFlow(io.droidbridge.relay.TrafficProfile())
    val capabilities= kotlinx.coroutines.flow.MutableStateFlow(0L)
}
