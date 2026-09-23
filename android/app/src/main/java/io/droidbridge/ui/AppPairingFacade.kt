package io.droidbridge.ui

import android.os.Build
import io.droidbridge.pairing.PairingCoordinator
import io.droidbridge.pairing.PairingServer
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.security.PairingSecretStore
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlin.time.Duration.Companion.seconds

/**
 * Wires the pairing screen to the real loopback PairingServer on 127.0.0.1:27184. Each "Pair New Mac"
 * opens a fresh 60-second window; the coordinator persists the peer only after both sides approve.
 */
class AppPairingFacade(
    private val store: PairingSecretStore,
    private val androidDisplayName: String = Build.MODEL ?: "Android",
    private val scope: CoroutineScope = CoroutineScope(Dispatchers.Default + SupervisorJob()),
    private val serverFactory: () -> PairingServer = { PairingServer() },
) : PairingFacade {
    private val _state = MutableStateFlow<PairingUiState>(PairingUiState.Closed)
    override val state: StateFlow<PairingUiState> = _state

    private var server: PairingServer? = null
    private var coordinator: PairingCoordinator? = null
    private var updates: Job? = null

    override fun beginPairing() {
        cancel()
        val pairingServer = serverFactory()
        try {
            pairingServer.open()
        } catch (_: IOException) {
            pairingServer.close()
            _state.value = PairingUiState.Failed("pairing port unavailable")
            return
        }
        server = pairingServer
        val coord = PairingCoordinator(
            store = store,
            acceptChannel = { pairingServer.acceptOne() },
            scope = scope,
            androidPeerId = UUID.randomUUID().toString(),
            androidDisplayName = androidDisplayName,
            onWindowClosed = { pairingServer.close() },
        )
        coordinator = coord
        updates = scope.launch { coord.state.collect { _state.value = it } }
        coord.openWindow(60.seconds)
    }

    override fun approve() { coordinator?.approve() }
    override fun reject() { coordinator?.reject() }
    override fun cancel() {
        updates?.cancel()
        updates = null
        coordinator?.cancel()
        coordinator = null
        server?.close()
        server = null
        _state.value = PairingUiState.Closed
    }
}
