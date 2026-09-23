package io.droidbridge

import android.content.Context
import android.content.Intent
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import io.droidbridge.relay.RelayForegroundService
import io.droidbridge.relay.RelayServiceController
import io.droidbridge.relay.ServiceBackedRelayController
import io.droidbridge.security.AndroidPairingSecretStore
import io.droidbridge.ui.RelayViewModel

/**
 * B1 wires a real relay controller and a placeholder pairing facade (the loopback pairing server is
 * driven from the pairing screen in a later step). Kept minimal so the app compiles and runs.
 */
class RelayViewModelFactory(private val context: Context) : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T {
        val controller = ServiceBackedRelayController(
            RelayServiceController.shared(context),
            startService = { context.startForegroundService(serviceIntent(RelayForegroundService.ACTION_START)) },
            stopService = { context.startService(serviceIntent(RelayForegroundService.ACTION_STOP)) },
        )
        val store = AndroidPairingSecretStore.create(context)
        val pairing = io.droidbridge.ui.AppPairingFacade(store)
        return RelayViewModel(controller, store, pairing) as T
    }

    private fun serviceIntent(action: String) =
        Intent(context, RelayForegroundService::class.java).setAction(action)
}
