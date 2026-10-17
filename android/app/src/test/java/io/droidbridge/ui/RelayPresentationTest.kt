package io.droidbridge.ui

import io.droidbridge.pairing.PairingUiState
import io.droidbridge.state.CellularStatus
import io.droidbridge.state.RelayStatus
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse

class RelayPresentationTest {
    private val connectedUsb = "USB accessory connected"

    @Test fun `setup action follows usb pair then start`() {
        val initial = RelayUiState()
        assertEquals(PrimaryAction.CONNECT_USB, presentRelay(initial, "USB disconnected").action)
        assertEquals(PrimaryAction.PAIR_MAC, presentRelay(initial, connectedUsb).action)
        assertEquals(PrimaryAction.START, presentRelay(initial.copy(pairedMacName = "MacBook"), connectedUsb).action)
    }

    @Test fun `pairing wait offers cancel and live approval stays modal`() {
        val waiting = RelayUiState(relayStatus=RelayStatus.RUNNING, pairing = PairingUiState.Listening(60))
        assertEquals(PrimaryAction.CANCEL_PAIRING, presentRelay(waiting, connectedUsb).action)
        val approval = waiting.copy(pairing = PairingUiState.AwaitingApproval("123456", "MacBook"))
        assertEquals(PrimaryAction.NONE, presentRelay(approval, connectedUsb).action)
    }

    @Test fun `running relay never asserts full mac internet connection`() {
        val state = RelayUiState(relayStatus = RelayStatus.RUNNING, cellularStatus = CellularStatus.AVAILABLE, pairedMacName = "MacBook")
        val connected = presentRelay(state, connectedUsb)
        assertEquals("공유 준비 완료", connected.title)
        assertEquals(PrimaryAction.STOP, connected.action)
        assertFalse(connected.description.contains("Mac 인터넷 연결됨"))
        assertEquals(ConnectionStep.USB, presentRelay(state, "USB disconnected").step)
    }

    @Test fun `traffic amounts use readable decimal units`() {
        assertEquals("0 B", humanBytes(-1))
        assertEquals("999 B", humanBytes(999))
        assertEquals("1.0 KB", humanBytes(1000))
        assertEquals("1.5 MB", humanBytes(1_500_000))
    }
}
