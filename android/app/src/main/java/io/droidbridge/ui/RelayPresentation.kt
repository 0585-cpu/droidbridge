package io.droidbridge.ui

import io.droidbridge.pairing.PairingUiState
import io.droidbridge.state.CellularStatus
import io.droidbridge.state.RelayStatus
import java.util.Locale

enum class PrimaryAction { CONNECT_USB, PAIR_MAC, CANCEL_PAIRING, START, STOP, NONE }
enum class ConnectionStep { USB, MAC, CELLULAR }

data class RelayPresentation(
    val title: String,
    val description: String,
    val actionLabel: String,
    val action: PrimaryAction,
    val usbConnected: Boolean,
    val step: ConnectionStep,
)

internal fun presentRelay(state: RelayUiState, usbStatus: String): RelayPresentation {
    val usbConnected = usbStatus == "USB accessory connected"
    val pairing = state.pairing
    return when {
        state.relayStatus == RelayStatus.STOPPING -> RelayPresentation("공유를 종료하는 중", "잠시만 기다려 주세요.", "종료 중", PrimaryAction.NONE, usbConnected, ConnectionStep.CELLULAR)
        state.relayStatus == RelayStatus.RUNNING && !usbConnected -> RelayPresentation("USB 연결을 확인해 주세요", "Android 공유는 실행 중이지만 USB 연결이 확인되지 않았습니다.", "공유 중지", PrimaryAction.STOP, usbConnected, ConnectionStep.USB)
        !usbConnected -> RelayPresentation("USB 케이블을 연결해 주세요", "Mac에서 이 휴대폰을 선택한 뒤 USB 접근을 허용해 주세요.", "USB 연결 확인", PrimaryAction.CONNECT_USB, false, ConnectionStep.USB)
        pairing is PairingUiState.Listening -> RelayPresentation("Mac 연결을 기다리는 중", "Mac에서 페어링을 시작해 주세요. 확인 코드를 함께 비교합니다.", "연결 대기 취소", PrimaryAction.CANCEL_PAIRING, true, ConnectionStep.MAC)
        pairing is PairingUiState.AwaitingApproval -> RelayPresentation("확인 코드를 비교해 주세요", "두 기기에 표시된 코드가 같은지 확인해 주세요.", "확인 중", PrimaryAction.NONE, true, ConnectionStep.MAC)
        pairing is PairingUiState.Failed -> RelayPresentation("Mac 연결에 실패했어요", "연결을 다시 시작하고 두 기기의 확인 코드를 비교해 주세요.", "다시 연결하기", PrimaryAction.PAIR_MAC, true, ConnectionStep.MAC)
        !state.isPaired -> RelayPresentation("Mac을 연결해 주세요", "처음 한 번만 Mac과 이 휴대폰을 안전하게 연결합니다.", "Mac 연결하기", PrimaryAction.PAIR_MAC, true, ConnectionStep.MAC)
        state.relayStatus == RelayStatus.STARTING -> RelayPresentation("모바일 네트워크 연결 중", "연결되면 Mac에서 공유를 사용할 수 있습니다.", "연결 취소", PrimaryAction.STOP, usbConnected, ConnectionStep.CELLULAR)
        state.relayStatus == RelayStatus.BLOCKED_CELLULAR -> RelayPresentation("모바일 네트워크 확인 필요", "휴대폰의 모바일 데이터 연결을 확인해 주세요.", "공유 중지", PrimaryAction.STOP, usbConnected, ConnectionStep.CELLULAR)
        state.relayStatus == RelayStatus.RUNNING -> RelayPresentation("공유 준비 완료", "Android가 Mac으로 보낼 인터넷 트래픽을 처리할 준비가 됐습니다.", "공유 중지", PrimaryAction.STOP, usbConnected, ConnectionStep.CELLULAR)
        state.relayStatus == RelayStatus.FAILED -> RelayPresentation("공유를 시작하지 못했어요", "아래 오류를 확인한 뒤 다시 시도해 주세요.", "다시 시작", PrimaryAction.START, true, ConnectionStep.CELLULAR)
        else -> RelayPresentation("공유할 준비가 됐어요", "모바일 데이터를 Mac과 공유하려면 시작해 주세요.", "인터넷 공유 시작", PrimaryAction.START, true, ConnectionStep.CELLULAR)
    }
}

internal fun humanBytes(bytes: Long): String {
    val value = bytes.coerceAtLeast(0).toDouble()
    val units = arrayOf("B", "KB", "MB", "GB", "TB")
    var amount = value
    var unit = 0
    while (amount >= 1000 && unit < units.lastIndex) {
        amount /= 1000
        unit++
    }
    return if (unit == 0) "${amount.toLong()} B" else String.format(Locale.KOREA, "%.1f %s", amount, units[unit])
}

internal fun cellularLabel(status: CellularStatus, carrier: String?): String = when (status) {
    CellularStatus.AVAILABLE -> carrier?.takeIf { it.isNotBlank() } ?: "모바일 데이터 연결됨"
    CellularStatus.REQUESTING -> "연결 확인 중"
    CellularStatus.LOST -> "연결 끊김"
    CellularStatus.UNAVAILABLE -> "연결되지 않음"
}
