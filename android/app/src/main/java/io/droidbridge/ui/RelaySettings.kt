package io.droidbridge.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.shape.RoundedCornerShape
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.protocol.Capability
import io.droidbridge.relay.TrafficProfile

internal data class TrafficProfileDraft(
    val ttl: String,
    val hop: String,
    val domains: String,
    val upload: String,
    val download: String,
    val burst: String,
) {
    companion object {
        fun from(profile: TrafficProfile) = TrafficProfileDraft(
            ttl = profile.socketPolicy.ipv4Ttl?.toString().orEmpty(),
            hop = profile.socketPolicy.ipv6HopLimit?.toString().orEmpty(),
            domains = profile.dnsSuffixes.joinToString(", "),
            upload = profile.uploadBytesPerSecond.toString(),
            download = profile.downloadBytesPerSecond.toString(),
            burst = profile.burstBytes.toString(),
        )
    }
}

@Composable
internal fun RelaySettings(state: RelayUiState, usbStatus: String, actions: RelayActions, draft: TrafficProfileDraft,
    onDraftChange: (TrafficProfileDraft) -> Unit, onForgetClick: () -> Unit,
    batteryState: BatteryOptimizationState = BatteryOptimizationState()) {
    Column(verticalArrangement = Arrangement.spacedBy(18.dp)) {
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("설정", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold)
            Text("Mac 연결과 인터넷 공유 옵션을 관리합니다.", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        SettingsSection("연결 안정성", "화면을 끈 상태에서도 USB 인터넷 공유를 유지하도록 설정합니다.") {
            Text(when (batteryState.isExempt) {
                true -> "배터리 최적화 예외 적용됨"
                false -> "배터리 최적화 예외 미적용"
                null -> "배터리 최적화 상태를 확인할 수 없습니다"
            }, modifier = Modifier.testTag("batteryOptimizationStatus"))
            Text("예외를 허용하면 백그라운드 연결 유지에 도움이 될 수 있으며 배터리 사용량이 늘 수 있습니다. 발열이나 제조사 실행 제한에 따른 끊김까지 방지하지는 않습니다.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (batteryState.isExempt != true) {
                OutlinedButton(onClick = actions.batterySettings,
                    modifier = Modifier.fillMaxWidth().testTag("batteryOptimizationRequest")) {
                    Text("배터리 최적화 예외 요청")
                }
            }
            if (batteryState.settingsUnavailable) {
                Text("시스템 화면을 열 수 없습니다. 휴대폰 설정의 앱 배터리 항목에서 DroidBridge를 확인해 주세요.",
                    color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
        }
        SettingsSection("연결된 Mac", state.pairedMacName ?: "연결된 Mac이 없습니다.") {
            if (state.pairing is PairingUiState.Listening) {
                Text("Mac의 연결 요청을 기다리고 있습니다.", style = MaterialTheme.typography.bodyMedium)
                TextButton(onClick = actions.cancelPairing) { Text("연결 대기 취소") }
            } else {
                OutlinedButton(onClick = actions.pair, modifier = Modifier.fillMaxWidth()) {
                    Text(if (state.isPaired) "다른 Mac 연결하기" else "Mac 연결하기")
                }
            }
            if (state.isPaired) {
                TextButton(onClick = onForgetClick, modifier = Modifier.fillMaxWidth()) { Text("이 Mac 연결 해제") }
            }
            if (state.pairing is PairingUiState.Failed) {
                Text("Mac 연결 실패: ${state.pairing.reason}", color = MaterialTheme.colorScheme.error)
            }
        }
        TrafficProfileSection(state, actions, draft, onDraftChange)
        SettingsSection("진단 정보", "연결 문제가 있을 때 확인하세요.") {
            DiagnosticLine("USB", usbStatus)
            DiagnosticLine("동시 TCP 연결", state.activeFlows.toString())
            DiagnosticLine("동시 UDP 연결", state.activeUdp.toString())
            DiagnosticLine("UDP 손실", state.udpDrops.toString())
            DiagnosticLine("IPv6", if (state.capabilities and Capability.TCP6 != 0L) "지원" else "사용 불가")
            DiagnosticLine("ICMP IPv4", if (state.capabilities and Capability.ICMP4 != 0L) "지원" else "사용 불가")
            DiagnosticLine("ICMP IPv6", if (state.capabilities and Capability.ICMP6 != 0L) "지원" else "사용 불가")
        }
        Spacer(Modifier.height(6.dp))
    }
}

@Composable
private fun TrafficProfileSection(state: RelayUiState, actions: RelayActions, draft: TrafficProfileDraft,
    onDraftChange: (TrafficProfileDraft) -> Unit) {
    val canEdit = state.canEditProfile
    SettingsSection("트래픽 설정", if (canEdit) "다음 공유 시작부터 적용됩니다." else "인터넷 공유를 중지하면 변경할 수 있습니다.") {
        Text("속도 제한", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        NumericField("업로드 제한 · 바이트/초", draft.upload, { onDraftChange(draft.copy(upload = it)) }, canEdit, "0이면 제한 없음", tag = "uploadLimitField")
        NumericField("다운로드 제한 · 바이트/초", draft.download, { onDraftChange(draft.copy(download = it)) }, canEdit, "0이면 제한 없음")
        NumericField("순간 전송 허용량 · 바이트", draft.burst, { onDraftChange(draft.copy(burst = it)) }, canEdit, "1,232–4,194,304")
        Text("속도 제한은 모든 연결에 함께 적용됩니다. 다운로드 제한은 모바일 데이터 수신 후 전달 속도를 조절합니다.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        HorizontalDivider()
        Text("네트워크 옵션", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold)
        NumericField("IPv4 TTL", draft.ttl, { onDraftChange(draft.copy(ttl = it)) }, canEdit, "비워 두면 시스템 기본값 · 1–255")
        NumericField("IPv6 Hop Limit", draft.hop, { onDraftChange(draft.copy(hop = it)) }, canEdit, "비워 두면 시스템 기본값 · 1–255")
        OutlinedTextField(
            value = draft.domains, onValueChange = { onDraftChange(draft.copy(domains = it)) }, enabled = canEdit,
            label = { Text("차단할 DNS 도메인") },
            supportingText = { Text("쉼표로 구분 · 예: ads.example, tracker.example") },
            modifier = Modifier.fillMaxWidth(),
        )
        Text("DNS 차단은 암호화된 DNS, 저장된 응답, IP 직접 연결에는 적용되지 않습니다.",
            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Button(
            onClick = { actions.saveProfile(draft.ttl, draft.hop, draft.domains, draft.upload, draft.download, draft.burst) },
            enabled = canEdit, modifier = Modifier.fillMaxWidth().height(50.dp),
        ) { Text("설정 저장") }
        state.profileError?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
    }
}

@Composable
private fun NumericField(label: String, value: String, onValueChange: (String) -> Unit, enabled: Boolean, helper: String, tag: String? = null) {
    OutlinedTextField(
        value = value, onValueChange = onValueChange, enabled = enabled,
        label = { Text(label) }, supportingText = { Text(helper) },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true, modifier = Modifier.fillMaxWidth().let { if (tag == null) it else it.testTag(tag) },
    )
}

@Composable
private fun SettingsSection(title: String, subtitle: String, content: @Composable () -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(22.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            content()
        }
    }
}

@Composable
private fun DiagnosticLine(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Spacer(Modifier.width(12.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1.4f))
    }
}
