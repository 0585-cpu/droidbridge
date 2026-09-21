package io.droidbridge.ui

import io.droidbridge.pairing.PairedPeer
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.relay.RelayMetricsSnapshot
import io.droidbridge.security.InMemoryPairingSecretStore
import io.droidbridge.state.RelayState
import io.droidbridge.state.RelayStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

private class FakeController : RelayController {
    override val state = MutableStateFlow(RelayState())
    override val metrics = MutableStateFlow(RelayMetricsSnapshot(0, 128, 0, 0))
    val events = mutableListOf<String>()
    var startCalls = 0
    override fun start() { startCalls++; events += "start"; state.value = state.value.copy(relayStatus = RelayStatus.RUNNING) }
    override fun stop() { events += "stop"; state.value = state.value.copy(relayStatus = RelayStatus.STOPPED) }
    override fun forgetPeer() { events += "forget" }
}

private class FakePairing : PairingFacade {
    override val state = MutableStateFlow<PairingUiState>(PairingUiState.Closed)
    val events = mutableListOf<String>()
    override fun beginPairing() { events += "pair" }
    override fun approve() { events += "approve" }
    override fun reject() { events += "reject" }
    override fun cancel() { events += "cancel" }
}

@OptIn(ExperimentalCoroutinesApi::class)
class RelayViewModelTest {
    private val dispatcher = StandardTestDispatcher()
    @BeforeTest fun setUp() = Dispatchers.setMain(dispatcher)
    @AfterTest fun tearDown() = Dispatchers.resetMain()

    @Test
    fun `start is disabled until a peer exists and cellular request can begin`() = runTest {
        val controller = FakeController()
        val vm = RelayViewModel(controller, InMemoryPairingSecretStore(), FakePairing())
        assertFalse(vm.uiState.value.canStart)
        vm.onStartClicked()
        assertEquals(0, controller.startCalls)
    }

    @Test
    fun `start works once a peer is registered`() = runTest {
        val controller = FakeController()
        val store = InMemoryPairingSecretStore().apply { replace(PairedPeer("mac", "MacBook", ByteArray(32) { 1 })) }
        val vm = RelayViewModel(controller, store, FakePairing())
        assertTrue(vm.uiState.value.canStart)
        vm.onStartClicked()
        assertEquals(1, controller.startCalls)
    }

    @Test
    fun `forget mac stops relay before deleting secret`() = runTest {
        val controller = FakeController()
        val store = InMemoryPairingSecretStore().apply { replace(PairedPeer("mac", "MacBook", ByteArray(32) { 1 })) }
        val vm = RelayViewModel(controller, store, FakePairing())
        vm.onForgetMacClicked()
        assertEquals(listOf("stop", "forget"), controller.events)
    }
}
