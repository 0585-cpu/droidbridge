package io.droidbridge.ui

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.security.PairingSecretStore
import io.droidbridge.state.CellularStatus
import io.droidbridge.state.RelayStatus
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.launchIn
import kotlinx.coroutines.flow.onEach

data class RelayUiState(
    val relayStatus: RelayStatus = RelayStatus.STOPPED,
    val cellularStatus: CellularStatus = CellularStatus.UNAVAILABLE,
    val pairedMacName: String? = null,
    val carrierName: String? = null,
    val activeFlows: Int = 0,
    val uploadedBytes: Long = 0,
    val downloadedBytes: Long = 0,
    val error: String? = null,
    val pairing: PairingUiState = PairingUiState.Closed,
) {
    val isPaired: Boolean get() = pairedMacName != null
    val canStart: Boolean get() = isPaired && (relayStatus == RelayStatus.STOPPED || relayStatus == RelayStatus.FAILED)
    val canStop: Boolean get() = relayStatus != RelayStatus.STOPPED && relayStatus != RelayStatus.STOPPING
}

class RelayViewModel(
    private val controller: RelayController,
    private val store: PairingSecretStore,
    private val pairing: PairingFacade,
) : ViewModel() {
    private val _uiState = MutableStateFlow(RelayUiState(pairedMacName = store.load()?.displayName))
    val uiState: StateFlow<RelayUiState> = _uiState

    init {
        combine(controller.state, controller.metrics, pairing.state) { relay, metrics, pairingState ->
            _uiState.value.copy(
                relayStatus = relay.relayStatus,
                cellularStatus = relay.cellularStatus,
                carrierName = relay.carrierName,
                activeFlows = metrics.activeFlows,
                uploadedBytes = metrics.uploadedBytes,
                downloadedBytes = metrics.downloadedBytes,
                error = relay.lastError,
                pairing = pairingState,
                pairedMacName = store.load()?.displayName,
            )
        }.onEach { _uiState.value = it }.launchIn(viewModelScope)
    }

    fun onStartClicked() { if (_uiState.value.canStart) controller.start() }
    fun onStopClicked() { if (_uiState.value.canStop) controller.stop() }

    fun onForgetMacClicked() {
        controller.stop()      // never delete the secret while the relay is still serving
        controller.forgetPeer()
        _uiState.value = _uiState.value.copy(pairedMacName = null)
    }

    fun onPairClicked() = pairing.beginPairing()
    fun onApprovePairing() = pairing.approve()
    fun onRejectPairing() = pairing.reject()
    fun onCancelPairing() = pairing.cancel()
}
