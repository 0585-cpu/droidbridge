package io.droidbridge.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.NavigationBarItemDefaults
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import io.droidbridge.pairing.PairingUiState
import io.droidbridge.state.CellularStatus
import io.droidbridge.state.RelayStatus
import io.droidbridge.usb.UsbAccessoryStatus

internal data class RelayActions(
    val connectUsb: () -> Unit = {},
    val pair: () -> Unit = {},
    val cancelPairing: () -> Unit = {},
    val approvePairing: () -> Unit = {},
    val rejectPairing: () -> Unit = {},
    val start: () -> Unit = {},
    val stop: () -> Unit = {},
    val forgetMac: () -> Unit = {},
    val batterySettings: () -> Unit = {},
    val saveProfile: (String, String, String, String, String, String) -> Unit = { _, _, _, _, _, _ -> },
)

@Composable
fun RelayScreen(viewModel: RelayViewModel, onConnectUSB: () -> Unit = {},
    batteryState: BatteryOptimizationState = BatteryOptimizationState(), onBatterySettings: () -> Unit = {}) {
    val state by viewModel.uiState.collectAsStateWithLifecycle()
    val usbStatus by UsbAccessoryStatus.state.collectAsStateWithLifecycle()
    RelayContent(
        state = state,
        usbStatus = usbStatus,
        batteryState = batteryState,
        actions = RelayActions(
            connectUsb = onConnectUSB,
            pair = viewModel::onPairClicked,
            cancelPairing = viewModel::onCancelPairing,
            approvePairing = viewModel::onApprovePairing,
            rejectPairing = viewModel::onRejectPairing,
            start = viewModel::onStartClicked,
            stop = viewModel::onStopClicked,
            forgetMac = viewModel::onForgetMacClicked,
            batterySettings = onBatterySettings,
            saveProfile = viewModel::saveProfile,
        ),
    )
}

@Composable
internal fun RelayContent(state: RelayUiState, usbStatus: String, actions: RelayActions = RelayActions(), initialTab: Int = 0,
    batteryState: BatteryOptimizationState = BatteryOptimizationState()) {
    var selectedTab by remember { mutableIntStateOf(initialTab) }
    var confirmForget by remember { mutableStateOf(false) }
    val connectionScroll = rememberScrollState()
    val settingsScroll = rememberScrollState()
    // Keep unsaved settings while switching tabs; a newly loaded profile replaces the draft.
    var profileDraft by remember(state.profile) { mutableStateOf(TrafficProfileDraft.from(state.profile)) }
    val presentation = presentRelay(state, usbStatus)

    Scaffold(
        modifier = Modifier.semantics { testTagsAsResourceId = true },
        contentWindowInsets = androidx.compose.foundation.layout.WindowInsets.safeDrawing,
        bottomBar = {
            NavigationBar(containerColor = MaterialTheme.colorScheme.surface) {
                val tabColors = NavigationBarItemDefaults.colors(
                    selectedIconColor = MaterialTheme.colorScheme.primary,
                    selectedTextColor = MaterialTheme.colorScheme.primary,
                    indicatorColor = MaterialTheme.colorScheme.primaryContainer,
                    unselectedIconColor = MaterialTheme.colorScheme.onSurfaceVariant,
                    unselectedTextColor = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                NavigationBarItem(
                    selected = selectedTab == 0,
                    onClick = { selectedTab = 0 },
                    icon = { Text("●", fontSize = 16.sp) },
                    label = { Text("연결") },
                    modifier = Modifier.testTag("connectionTab"),
                    colors = tabColors,
                )
                NavigationBarItem(
                    selected = selectedTab == 1,
                    onClick = { selectedTab = 1 },
                    icon = { Text("⚙", fontSize = 19.sp) },
                    label = { Text("설정") },
                    modifier = Modifier.testTag("settingsTab"),
                    colors = tabColors,
                )
            }
        },
    ) { insets ->
        Box(Modifier.fillMaxSize().padding(insets)) {
            Column(
                modifier = Modifier.align(Alignment.TopCenter).widthIn(max = 520.dp)
                    .fillMaxWidth().verticalScroll(if (selectedTab == 0) connectionScroll else settingsScroll)
                    .padding(horizontal = 24.dp, vertical = 24.dp),
            ) {
                AppHeader()
                Spacer(Modifier.height(30.dp))
                if (selectedTab == 0) {
                    ConnectionHome(state, usbStatus, presentation, actions)
                } else {
                    RelaySettings(state, usbStatus, actions, profileDraft, onDraftChange = { profileDraft = it },
                        onForgetClick = { confirmForget = true }, batteryState = batteryState)
                }
            }
        }
    }

    // Approval must remain visible even if the current tab is scrolled to the bottom.
    val pairing = state.pairing
    if (pairing is PairingUiState.AwaitingApproval) {
        AlertDialog(
            onDismissRequest = actions.rejectPairing,
            title = { Text("Mac 연결 확인") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text("Mac에 표시된 코드와 아래 코드가 같은지 비교해 주세요.")
                    Text(pairing.sas, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                    Text("연결 요청: ${pairing.macDisplayName}", color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("코드를 입력할 필요는 없습니다. 두 코드가 같을 때만 승인하세요.")
                }
            },
            confirmButton = { TextButton(onClick = actions.approvePairing) { Text("코드가 같아요") } },
            dismissButton = { TextButton(onClick = actions.rejectPairing) { Text("거부") } },
        )
    }
    if (confirmForget) {
        AlertDialog(
            onDismissRequest = { confirmForget = false },
            title = { Text("Mac 연결을 해제할까요?") },
            text = { Text("${state.pairedMacName ?: "이 Mac"}과의 보안 연결이 삭제되고 인터넷 공유가 중지됩니다. 다시 연결하려면 새로 페어링해야 합니다.") },
            confirmButton = { TextButton(onClick = { confirmForget = false; actions.forgetMac() }) { Text("연결 해제") } },
            dismissButton = { TextButton(onClick = { confirmForget = false }) { Text("취소") } },
        )
    }
}

@Composable
private fun AppHeader() {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(42.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(13.dp)), contentAlignment = Alignment.Center) {
            Text("↔", color = MaterialTheme.colorScheme.onPrimary, fontSize = 27.sp, fontWeight = FontWeight.Bold)
        }
        Column {
            Text("DroidBridge", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text("USB로 Mac과 인터넷 공유", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

@Composable
private fun ConnectionHome(state: RelayUiState, usbStatus: String, presentation: RelayPresentation, actions: RelayActions) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
        ConnectionArtwork(Modifier.size(186.dp))
        Spacer(Modifier.height(12.dp))
        Text(presentation.title, style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth().testTag("connectionStatus"))
        Spacer(Modifier.height(10.dp))
        Text(presentation.description, style = MaterialTheme.typography.bodyLarge,
            color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        Spacer(Modifier.height(27.dp))
        Button(
            onClick = {
                when (presentation.action) {
                    PrimaryAction.CONNECT_USB -> actions.connectUsb()
                    PrimaryAction.PAIR_MAC -> actions.pair()
                    PrimaryAction.CANCEL_PAIRING -> actions.cancelPairing()
                    PrimaryAction.START -> actions.start()
                    PrimaryAction.STOP -> actions.stop()
                    PrimaryAction.NONE -> Unit
                }
            },
            enabled = presentation.action != PrimaryAction.NONE,
            modifier = Modifier.fillMaxWidth().height(56.dp).testTag("primaryAction"),
            shape = RoundedCornerShape(17.dp),
        ) { Text(presentation.actionLabel, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold) }
        if (presentation.action == PrimaryAction.CONNECT_USB) {
            Spacer(Modifier.height(12.dp))
            Text("케이블 연결 후 Mac에서 DroidBridge를 열어 주세요.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        Spacer(Modifier.height(30.dp))
        ProgressCard(state, usbStatus, presentation)
        Spacer(Modifier.height(18.dp))
        TrafficCards(state)
        state.error?.takeIf { it.isNotBlank() }?.let {
            Spacer(Modifier.height(18.dp))
            Surface(color = MaterialTheme.colorScheme.errorContainer, shape = RoundedCornerShape(18.dp), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp)) {
                    Text("연결 알림", fontWeight = FontWeight.Bold, color = MaterialTheme.colorScheme.onErrorContainer)
                    Spacer(Modifier.height(4.dp))
                    Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onErrorContainer)
                }
            }
        }
    }
}

@Composable
private fun ConnectionArtwork(modifier: Modifier = Modifier) {
    val line = MaterialTheme.colorScheme.primary
    val paper = MaterialTheme.colorScheme.surface
    val soft = MaterialTheme.colorScheme.primaryContainer
    val ink = MaterialTheme.colorScheme.onSurface
    Canvas(modifier) {
        val w = size.width
        val h = size.height
        drawCircle(soft, radius = w * .47f, center = Offset(w / 2, h / 2))
        drawRoundRect(ink, topLeft = Offset(w * .34f, h * .13f), size = Size(w * .32f, h * .49f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * .055f), style = Stroke(width = w * .019f))
        drawRoundRect(paper, topLeft = Offset(w * .365f, h * .19f), size = Size(w * .27f, h * .32f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * .022f))
        drawLine(line, Offset(w * .45f, h * .16f), Offset(w * .55f, h * .16f), strokeWidth = w * .013f)
        drawCircle(line, radius = w * .015f, center = Offset(w * .5f, h * .56f))
        val cable = Path().apply {
            moveTo(w * .5f, h * .62f)
            lineTo(w * .5f, h * .69f)
            cubicTo(w * .5f, h * .87f, w * .8f, h * .86f, w * .8f, h * .73f)
        }
        drawPath(cable, line, style = Stroke(width = w * .028f, cap = androidx.compose.ui.graphics.StrokeCap.Round))
        drawRoundRect(line, topLeft = Offset(w * .75f, h * .65f), size = Size(w * .1f, h * .085f),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(w * .02f))
        drawLine(line, Offset(w * .77f, h * .64f), Offset(w * .77f, h * .61f), strokeWidth = w * .012f)
        drawLine(line, Offset(w * .83f, h * .64f), Offset(w * .83f, h * .61f), strokeWidth = w * .012f)
    }
}

@Composable
private fun ProgressCard(state: RelayUiState, usbStatus: String, presentation: RelayPresentation) {
    Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(22.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(17.dp)) {
            Text("연결 상태", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            StepLine("USB 연결", if (presentation.usbConnected) "연결됨" else usbStatus.let { if (it.contains("denied", ignoreCase = true) || it.contains("거부")) "접근 권한 필요" else "대기 중" }, presentation.usbConnected)
            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = .45f))
            StepLine("Mac 연결", state.pairedMacName ?: when (state.pairing) {
                is PairingUiState.Listening -> "연결 요청 대기 중"
                is PairingUiState.AwaitingApproval -> "코드 확인 중"
                else -> "연결되지 않음"
            }, state.isPaired)
            HorizontalDivider(color = MaterialTheme.colorScheme.outline.copy(alpha = .45f))
            val cellularReady = state.relayStatus == RelayStatus.RUNNING && state.cellularStatus == CellularStatus.AVAILABLE
            StepLine("모바일 데이터", if (state.relayStatus == RelayStatus.STOPPED) "공유 대기 중" else cellularLabel(state.cellularStatus, state.carrierName), cellularReady)
        }
    }
}

@Composable
private fun StepLine(label: String, value: String, ready: Boolean) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(22.dp).background(if (ready) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceVariant, CircleShape), contentAlignment = Alignment.Center) {
            Text(if (ready) "✓" else "·", color = if (ready) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.width(11.dp))
        Text(label, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Text(value, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.End, modifier = Modifier.weight(1.3f))
    }
}

@Composable
private fun TrafficCards(state: RelayUiState) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        TrafficTile("업로드", "↑", humanBytes(state.uploadedBytes), "${humanBytes(state.uploadRate)}/초", Modifier.weight(1f))
        TrafficTile("다운로드", "↓", humanBytes(state.downloadedBytes), "${humanBytes(state.downloadRate)}/초", Modifier.weight(1f))
    }
}

@Composable
private fun TrafficTile(label: String, arrow: String, total: String, rate: String, modifier: Modifier) {
    Surface(color = MaterialTheme.colorScheme.surface, shape = RoundedCornerShape(22.dp), modifier = modifier) {
        Column(Modifier.padding(17.dp), verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("$arrow  $label", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(total, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            Text(rate, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}
