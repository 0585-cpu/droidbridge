package io.droidbridge.relay

import android.content.Context
import android.net.ConnectivityManager
import android.telephony.TelephonyManager
import io.droidbridge.network.AndroidCellularTransport
import io.droidbridge.network.CellularNetworkController
import io.droidbridge.network.CellularState
import io.droidbridge.security.AndroidPairingSecretStore
import io.droidbridge.security.EpochClock
import io.droidbridge.security.NonceReplayCache
import io.droidbridge.security.PairingSecretStore
import io.droidbridge.security.SessionAuthenticator
import io.droidbridge.state.RelayState
import io.droidbridge.ui.RelayController
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch

/**
 * Orchestrates the relay lifecycle on the device: selects the cellular network, runs the loopback
 * RelayServer, and maps cellular events onto the fail-closed RelayState the UI observes.
 */
class RelayServiceController(
    private val store: PairingSecretStore,
    private val controller: CellularNetworkController,
) : RelayController {

    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val _state = MutableStateFlow(RelayState())
    override val state: StateFlow<RelayState> = _state

    private val backend = AndroidRelayBackend(controller)
    private val server = RelayServer(
        SessionAuthenticator({ store.load()?.secret }, NonceReplayCache(clock = EpochClock.SYSTEM), EpochClock.SYSTEM),
        backend,
    )
    override val metrics = server.metrics.snapshot

    init {
        controller.addLossListener(server::cancelActiveFlows)
        scope.launch {
            controller.state.collect { cellular ->
                _state.value = when (cellular) {
                    is CellularState.Available -> _state.value.onCellularAvailable(cellular.carrierName)
                    CellularState.Lost, CellularState.Unavailable -> _state.value.onCellularLost("cellular unavailable")
                    CellularState.Requesting -> _state.value
                }
            }
        }
    }

    override fun start() {
        _state.value = _state.value.onStartRequested()
        controller.start()
        server.start()
    }

    override fun stop() {
        _state.value = _state.value.onStopRequested()
        server.stop()
        controller.stop()
        _state.value = _state.value.onStopped()
    }

    override fun forgetPeer() {
        store.clear()
    }

    fun shutdown() = scope.cancel()

    companion object {
        @Volatile private var shared: RelayServiceController? = null

        /**
         * The single relay for this process. The foreground service and the UI must share it: two
         * instances would both try to own the loopback relay port and would disagree about state.
         */
        fun shared(context: Context): RelayServiceController =
            shared ?: synchronized(this) { shared ?: create(context.applicationContext).also { shared = it } }

        fun create(context: Context): RelayServiceController {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
            val store = AndroidPairingSecretStore.create(context)
            return RelayServiceController(store, CellularNetworkController(AndroidCellularTransport(cm, tm)))
        }
    }
}
