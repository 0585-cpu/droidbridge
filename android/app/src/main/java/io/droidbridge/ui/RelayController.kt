package io.droidbridge.ui

import io.droidbridge.relay.RelayMetricsSnapshot
import io.droidbridge.state.RelayState
import kotlinx.coroutines.flow.StateFlow

/** What the UI drives: the relay lifecycle plus the single-peer registration. */
interface RelayController {
    val state: StateFlow<RelayState>
    val metrics: StateFlow<RelayMetricsSnapshot>
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
