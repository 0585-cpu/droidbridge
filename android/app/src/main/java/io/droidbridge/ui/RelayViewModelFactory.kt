package io.droidbridge

import android.content.Context
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.relay.RelayServiceController
import io.droidbridge.security.AndroidPairingSecretStore
import io.droidbridge.ui.PairingFacade
import io.droidbridge.ui.RelayViewModel
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * B1 wires a real relay controller and a placeholder pairing facade (the loopback pairing server is
 * driven from the pairing screen in a later step). Kept minimal so the app compiles and runs.
 */
class RelayViewModelFactory(private val context: Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        val controller = RelayServiceController.create(context)
        val store = AndroidPairingSecretStore.create(context)
        val pairing = object : PairingFacade {
            override val state = MutableStateFlow<PairingUiState>(PairingUiState.Closed)
            override fun beginPairing() {}
            override fun approve() {}
            override fun reject() {}
            override fun cancel() {}
        }
        return RelayViewModel(controller, store, pairing) as T
    }
}
