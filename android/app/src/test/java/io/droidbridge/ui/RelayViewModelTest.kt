package io.droidbridge.ui

import io.droidbridge.pairing.PairedPeer
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.relay.RelayMetricsSnapshot
import io.droidbridge.security.InMemoryPairingSecretStore
import io.droidbridge.security.AndroidPairingSecretStore
import io.droidbridge.security.FakePrefs
import io.droidbridge.security.PairingSecretStore
import androidx.lifecycle.ViewModelStore
import javax.crypto.KeyGenerator
import io.droidbridge.state.RelayState
import io.droidbridge.state.RelayStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.runCurrent
import kotlin.test.AfterTest
import kotlin.test.BeforeTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.assertNull

private class FakeController(private val store: PairingSecretStore? = null) : RelayController {
    override val state = MutableStateFlow(RelayState())
    override val metrics = MutableStateFlow(RelayMetricsSnapshot(0, 128, 0, 0))
    val events = mutableListOf<String>()
    var startCalls = 0
    override fun start() { startCalls++; events += "start"; state.value = state.value.copy(relayStatus = RelayStatus.RUNNING) }
    override fun stop() { events += "stop"; state.value = state.value.copy(relayStatus = RelayStatus.STOPPED) }
    override fun forgetPeer() { events += "forget"; store?.clear() }
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
    private val viewModels = ViewModelStore()
    @BeforeTest fun setUp() = Dispatchers.setMain(dispatcher)
    @AfterTest fun tearDown() { viewModels.clear(); Dispatchers.resetMain() }

    private fun viewModel(controller: RelayController, store: PairingSecretStore, pairing: PairingFacade) =
        RelayViewModel(controller, store, pairing).also { viewModels.put("relay", it) }

    @Test
    fun `start is disabled until a peer exists and cellular request can begin`() = runTest {
        val controller = FakeController()
        val vm = viewModel(controller, InMemoryPairingSecretStore(), FakePairing())
        assertFalse(vm.uiState.value.canStart)
        vm.onStartClicked()
        assertEquals(0, controller.startCalls)
    }

    @Test
    fun `start works once a peer is registered`() = runTest {
        val controller = FakeController()
        val store = InMemoryPairingSecretStore().apply { replace(PairedPeer("mac", "MacBook", ByteArray(32) { 1 })) }
        val vm = viewModel(controller, store, FakePairing())
        assertTrue(vm.uiState.value.canStart)
        vm.onStartClicked()
        assertEquals(1, controller.startCalls)
    }

    @Test
    fun `forget mac stops relay before deleting secret`() = runTest {
        val controller = FakeController()
        val store = InMemoryPairingSecretStore().apply { replace(PairedPeer("mac", "MacBook", ByteArray(32) { 1 })) }
        val pairing = FakePairing()
        val vm = viewModel(controller, store, pairing)
        vm.onForgetMacClicked()
        assertEquals(listOf("cancel"), pairing.events)
        assertEquals(listOf("stop", "forget"), controller.events)
    }

    @Test
    fun `traffic and relay updates do not decrypt the paired peer again`() = runTest {
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        var keyOperations = 0
        val store = AndroidPairingSecretStore(FakePrefs()) { keyOperations++; key }
        store.replace(PairedPeer("mac", "MacBook", ByteArray(32) { 1 }))
        val controller = FakeController(store)
        val vm = viewModel(controller, store, FakePairing())
        runCurrent()
        val initialOperations = keyOperations

        repeat(1_000) { index ->
            controller.metrics.value = RelayMetricsSnapshot(1, 128, index.toLong(), index * 65_536L)
            controller.state.value = controller.state.value.copy(carrierName = "carrier-$index")
            runCurrent()
        }

        assertEquals(999 * 65_536L, vm.uiState.value.downloadedBytes)
        assertEquals("MacBook", vm.uiState.value.pairedMacName)
        assertEquals(initialOperations, keyOperations, "traffic must not trigger storage key operations")
    }

    @Test
    fun `pairing completion refreshes the name and forgetting is not undone by later traffic`() = runTest {
        val store = InMemoryPairingSecretStore()
        val controller = FakeController(store)
        val pairing = FakePairing()
        val vm = viewModel(controller, store, pairing)
        runCurrent()
        pairing.state.value = PairingUiState.Listening(60)
        runCurrent()
        store.replace(PairedPeer("mac", "New Mac", ByteArray(32) { 2 }))
        pairing.state.value = PairingUiState.Completed("New Mac")
        runCurrent()
        assertEquals("New Mac", vm.uiState.value.pairedMacName)
        assertTrue(vm.uiState.value.canStart)

        vm.onForgetMacClicked()
        controller.metrics.value = RelayMetricsSnapshot(0, 128, 100, 200)
        runCurrent()
        assertNull(vm.uiState.value.pairedMacName)
        assertFalse(vm.uiState.value.canStart)
    }

    @Test
    fun `screen observes encrypted pairing writes through another store instance`() = runTest {
        val prefs = FakePrefs()
        val key = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
        val writer = AndroidPairingSecretStore(prefs) { key }
        val reader = AndroidPairingSecretStore(prefs) { key }
        val vm = viewModel(FakeController(writer), reader, FakePairing())
        runCurrent()
        writer.replace(PairedPeer("mac", "Other facade", ByteArray(32) { 4 }))
        runCurrent()
        assertEquals("Other facade", vm.uiState.value.pairedMacName)
        writer.clear()
        runCurrent()
        assertNull(vm.uiState.value.pairedMacName)
        viewModels.clear()
        runCurrent()
        assertEquals(0, prefs.listeners.size, "cleared ViewModels must unregister preference observers")
    }

    @Test
    fun `recreated screen observes persistence from a previous pairing facade`() = runTest {
        val store = InMemoryPairingSecretStore()
        val oldPairing = FakePairing()
        viewModel(FakeController(store), store, oldPairing)
        runCurrent()
        oldPairing.state.value = PairingUiState.AwaitingApproval("123456", "MacBook")
        runCurrent()
        // Replacing the ViewModel does not make its old facade the new screen's facade.
        val newPairing = FakePairing()
        val reopened = viewModel(FakeController(store), store, newPairing)
        runCurrent()
        store.replace(PairedPeer("mac", "MacBook", ByteArray(32) { 3 }))
        oldPairing.state.value = PairingUiState.Completed("MacBook")
        runCurrent()
        assertEquals(PairingUiState.Closed, newPairing.state.value)
        assertEquals("MacBook", reopened.uiState.value.pairedMacName)
        assertTrue(reopened.uiState.value.canStart)
        store.clear()
        runCurrent()
        assertNull(reopened.uiState.value.pairedMacName)
    }

    @Test
    fun `failed pairing refreshes the persisted peer even when completion was not delivered`() = runTest {
        val store = InMemoryPairingSecretStore().apply { replace(PairedPeer("old", "Old Mac", ByteArray(32) { 1 })) }
        val pairing = FakePairing()
        val vm = viewModel(FakeController(store), store, pairing)
        runCurrent()
        pairing.state.value = PairingUiState.Listening(60)
        runCurrent()
        // The coordinator persists before sending the final approval; that write can fail.
        store.replace(PairedPeer("new", "New Mac", ByteArray(32) { 2 }))
        pairing.state.value = PairingUiState.Failed("connection error")
        runCurrent()
        assertEquals("New Mac", vm.uiState.value.pairedMacName)
    }
}
