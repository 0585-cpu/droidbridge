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
    private val profileStore: TrafficProfileStore = MemoryTrafficProfileStore(),
    private val relayPort: Int = RelayServer.DBP_PORT,
) : RelayController {

    private val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private val _state = MutableStateFlow(RelayState())
    override val state: StateFlow<RelayState> = _state

    private val _profile = MutableStateFlow(profileStore.load())
    override val profile: StateFlow<TrafficProfile> = _profile
    private val _capabilities = MutableStateFlow(0L)
    override val capabilities: StateFlow<Long> = _capabilities
    private val backend = AndroidRelayBackend(controller)
    private val server = RelayServer(
        SessionAuthenticator({ store.load()?.secret }, NonceReplayCache(clock = EpochClock.SYSTEM), EpochClock.SYSTEM),
        backend,
    )
    override val metrics = server.metrics.snapshot

    init {
        controller.addLossListener(server::cancelActiveFlows)
        scope.launch {
            while(true) { _capabilities.value=backend.capabilities().flags; server.metrics.tick(); kotlinx.coroutines.delay(1000) }
        }
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

    @Synchronized override fun start() {
        if (server.port >= 0) return
        _state.value = _state.value.onStartRequested()
        backend.beginRun(_profile.value)
        controller.start()
        server.start(relayPort)
    }

    @Synchronized override fun stop() {
        _state.value = _state.value.onStopRequested()
        server.stop()
        controller.stop()
        _state.value = _state.value.onStopped()
    }

    @Synchronized override fun updateProfile(profile: TrafficProfile): Boolean {
        if(server.port>=0 || _state.value.relayStatus !in listOf(io.droidbridge.state.RelayStatus.STOPPED,io.droidbridge.state.RelayStatus.FAILED)) return false
        val snapshot=profile.copy(dnsSuffixes=profile.dnsSuffixes.toList())
        profileStore.save(snapshot); _profile.value=snapshot
        return true
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
            return RelayServiceController(store, CellularNetworkController(AndroidCellularTransport(cm, tm)), AndroidTrafficProfileStore(context.getSharedPreferences("traffic-profile",Context.MODE_PRIVATE)))
        }
    }
}
