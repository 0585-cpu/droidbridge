package io.droidbridge.ui

import androidx.lifecycle.ViewModelStore
import io.droidbridge.pairing.PairingCoordinator
import io.droidbridge.pairing.PairingServer
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.relay.RelayMetricsSnapshot
import io.droidbridge.security.InMemoryPairingSecretStore
import io.droidbridge.state.CellularStatus
import io.droidbridge.state.RelayState
import io.droidbridge.state.RelayStatus
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds

/** Real sockets exercise timeout and screen ownership rather than cancellable fake channels. */
@OptIn(ExperimentalCoroutinesApi::class)
class PairingLifecycleRegressionTest {
    @Test fun `real listener expires without a client`() = runBlocking {
        val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
        val server = PairingServer(0)
        val entered = CompletableDeferred<Unit>()
        server.open()
        val coordinator = PairingCoordinator(InMemoryPairingSecretStore(), {
            entered.complete(Unit)
            server.acceptOne()
        }, scope, "test", "Test Android", onWindowClosed = server::close)
        val job = coordinator.openWindow(200.milliseconds)
        try {
            withTimeout(5_000) { entered.await() }
            delay(750)
            println("timeout=200ms observedAfter=750ms completed=${job.isCompleted} state=${coordinator.state.value} portBound=${server.boundPort > 0}")
            assertTrue(job.isCompleted, "Expired pairing still blocks in real ServerSocket.accept")
            assertEquals(PairingUiState.Closed, coordinator.state.value)
        } finally {
            coordinator.cancel()
            server.close()
            withTimeout(5_000) { job.join() }
            scope.cancel()
        }
    }

    @Test fun `destroyed screen releases its pairing listener for the next screen`(): Unit = runBlocking {
        Dispatchers.setMain(UnconfinedTestDispatcher())
        val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
        val store = InMemoryPairingSecretStore()
        val models = ViewModelStore()
        lateinit var firstServer: PairingServer
        val first = AppPairingFacade(store, "Test Android", scope) {
            PairingServer(0).also { firstServer = it }
        }
        var second: AppPairingFacade? = null
        try {
            val old = RelayViewModel(controller(), store, first)
            models.put("relay", old)
            old.onPairClicked()
            val port = firstServer.boundPort
            models.clear()
            second = AppPairingFacade(store, "Test Android", scope) { PairingServer(port) }
            val reopened = RelayViewModel(controller(), store, second)
            models.put("relay", reopened)
            reopened.onPairClicked()
            println("oldPortStillBound=${firstServer.boundPort > 0} newPairing=${second.state.value}")
            withTimeout(1000) { while (second.state.value is PairingUiState.Closed) delay(5) }
            assertIs<PairingUiState.Listening>(second.state.value,
                "New screen cannot pair because destroyed screen still owns the port")
        } finally {
            models.clear()
            first.cancel()
            second?.cancel()
            scope.cancel()
            Dispatchers.resetMain()
        }
    }

    @Test fun `unpaired phone with active USB still prompts to pair`() {
        val state = RelayUiState(relayStatus = RelayStatus.RUNNING,
            cellularStatus = CellularStatus.AVAILABLE, pairedMacName = null)
        val presentation = presentRelay(state, "USB accessory connected")
        println("unpairedPhone title=${presentation.title} action=${presentation.action}")
        assertEquals(PrimaryAction.PAIR_MAC, presentation.action,
            "Opening USB starts the relay before pairing but hides the pairing action")
    }

    private fun controller(): RelayController = object : RelayController {
        override val state = MutableStateFlow(RelayState())
        override val metrics = MutableStateFlow(RelayMetricsSnapshot(0, 128, 0, 0))
        override fun start() {}
        override fun stop() {}
        override fun forgetPeer() {}
    }
}
