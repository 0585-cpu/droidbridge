import SwiftUI
import DroidBridgeShared

private enum DashboardPage: String, CaseIterable {
    case connection = "연결"
    case settings = "설정"
}

struct MenuBarContentView: View {
    @Bindable var adapter: DroidBridgeCoordinatorAdapter
    @State private var page = DashboardPage.connection
    @State private var actionRunning = false
    @State private var confirmForget = false
    @State private var confirmRemoval = false
    private let accent = Color(red: 200.0 / 255, green: 75.0 / 255, blue: 64.0 / 255)

    private var presentation: HostConnectionPresentation {
        .make(state: adapter.state, runtime: adapter.tunnelMetrics?.runtimeStatus,
              tunnelActive: adapter.tunnelRunning, busy: adapter.helperOperationInProgress,
              paired: adapter.canPrepareRelay)
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .connected: Color(red: 0.16, green: 0.55, blue: 0.41)
        case .warning: Color(red: 0.76, green: 0.43, blue: 0.10)
        case .accent: accent
        case .neutral: .secondary
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 21, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 2) {
                    Text("DroidBridge").font(.system(size: 18, weight: .bold))
                    Text("USB로 연결하는 모바일 인터넷").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(statusColor).frame(width: 8, height: 8)
                    .accessibilityLabel(presentation.title)
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 18)

            Picker("화면", selection: $page) {
                ForEach(DashboardPage.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 18) {
                    if page == .connection { connectionPage } else { settingsPage }
                }
                .padding(.horizontal, 24).padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .frame(minWidth: 440, idealWidth: 460, maxWidth: 620, minHeight: 620, idealHeight: 690)
        .task {
            adapter.startMonitoring()
            await adapter.refreshTunnelStatus()
        }
        .sheet(isPresented: Binding(
            get: { if case .pairing(let code) = adapter.state { return code != nil }; return false },
            set: { if !$0 { adapter.rejectPairing() } }
        )) {
            if case .pairing(let code) = adapter.state {
                PairingApprovalView(sas: code, onApprove: adapter.approvePairing, onReject: adapter.rejectPairing)
                    .id(code)
            }
        }
        .alert("페어링을 해제할까요?", isPresented: $confirmForget) {
            Button("취소", role: .cancel) {}
            Button("페어링 해제", role: .destructive) { Task { await adapter.forgetPairing() } }
        } message: {
            Text("사용 중인 연결을 종료합니다. 다시 사용하려면 휴대폰과 확인 코드를 비교해야 해요.")
        }
        .alert("네트워크 도구를 제거할까요?", isPresented: $confirmRemoval) {
            Button("취소", role: .cancel) {}
            Button("제거", role: .destructive) { Task { await adapter.uninstallHelper() } }
        } message: {
            Text("먼저 연결을 해제한 뒤 관리자 승인으로 도구를 제거합니다. 다음 연결 때 다시 설치할 수 있어요.")
        }
    }

    private var connectionPage: some View {
        VStack(spacing: 20) {
            VStack(spacing: 14) {
                ZStack {
                    Circle().fill(statusColor.opacity(0.055)).frame(width: 116, height: 116)
                    Circle().stroke(statusColor.opacity(0.17), lineWidth: 1).frame(width: 92, height: 92)
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 34, weight: .medium)).foregroundStyle(statusColor)
                }
                .accessibilityHidden(true)
                .padding(.top, 6)
                Text(presentation.title).font(.system(size: 24, weight: .bold))
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                Text(presentation.detail).font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                if presentation.isBusy { ProgressView().controlSize(.small).accessibilityLabel("연결 상태 확인 중") }
            }
            .frame(maxWidth: .infinity)

            if let message = adapter.networkRecoveryMessage {
                Label(message, systemImage: "arrow.uturn.backward.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .deviceSelectionRequired(let devices) = adapter.state {
                DevicePickerView(devices: devices) { device in Task { await adapter.selectDevice(device) } }
            }

            if presentation.action != .none {
                Button { performPrimaryAction() } label: {
                    HStack(spacing: 8) {
                        if actionRunning { ProgressView().controlSize(.small) }
                        Text(presentation.actionTitle).font(.system(size: 15, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity).frame(height: 42)
                }
                .buttonStyle(ConnectionActionButtonStyle(color: accent))
                .disabled(actionRunning || adapter.helperOperationInProgress)
            }

            if !adapter.tunnelRunning && adapter.canRestoreNetwork {
                Button("네트워크 설정 복원") { Task { await adapter.stopTunnel() } }
                    .disabled(actionRunning || adapter.helperOperationInProgress || isPairing)
                    .help("인터넷이 막혀 있거나 연결 상태를 확인할 수 없을 때 DroidBridge 설정을 해제합니다.")
            }

            if adapter.tunnelMetrics?.runtimeStatus == .persistentBlockedRelay || adapter.tunnelMetrics?.runtimeStatus == .persistentBlockedCellular {
                Button("다시 연결") { Task { await adapter.reconnectTunnel() } }
                    .disabled(adapter.helperOperationInProgress || actionRunning)
            }

            VStack(spacing: 0) {
                infoRow("iphone.gen3", "휴대폰", deviceText)
                Divider().padding(.leading, 44)
                infoRow("personalhotspot", "모바일 데이터", cellularText)
            }
            .padding(14).background(cardBackground, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 12) {
                trafficTile("업로드", symbol: "arrow.up", bytes: adapter.tunnelMetrics?.uploadedBytes ?? 0)
                trafficTile("다운로드", symbol: "arrow.down", bytes: adapter.tunnelMetrics?.downloadedBytes ?? 0)
            }

            if let message = adapter.tunnelMessage, !presentation.isBusy, !isPairing {
                DisclosureGroup {
                    Text(message).font(.caption).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                } label: {
                    Label("연결 안내 · 자세히 보기", systemImage: "info.circle").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Text("Android → USB → Mac")
                .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            settingsSection("연결 관리", subtitle: "휴대폰과의 연결을 확인하고 관리해요.") {
                settingsButton("연결 상태 새로고침", symbol: "arrow.clockwise") {
                    Task { await adapter.refresh(); await adapter.refreshTunnelStatus() }
                }
                if adapter.canPrepareRelay && !adapter.tunnelRunning {
                    settingsButton("휴대폰 연결 확인", symbol: "checkmark.shield") { Task { await adapter.prepareRelay() } }
                }
                if adapter.hasPairing {
                    settingsButton("페어링 해제", symbol: "link.badge.plus", destructive: true) { confirmForget = true }
                }
            }
            settingsSection("트래픽 설정", subtitle: "휴대폰 앱의 설정에서 변경할 수 있어요.") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("TTL · Hop Limit · DNS 차단 · 속도 제한")
                        .font(.system(size: 13, weight: .medium))
                    Text("인터넷 공유를 중지한 뒤 Android DroidBridge의 ‘설정’을 열어 주세요. 저장한 설정은 다음 연결에 적용됩니다.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3)
                }.padding(14)
            }
            settingsSection("연결 정보", subtitle: "문제가 생겼을 때 참고할 진단 정보예요.") {
                VStack(spacing: 11) {
                    diagnosticRow("연결 방식", "USB 액세서리")
                    diagnosticRow("통신사", carrierName ?? "—")
                    diagnosticRow("활성 연결", String(adapter.tunnelMetrics?.activeFlows ?? 0))
                    diagnosticRow("UDP 연결", String(adapter.tunnelMetrics?.activeUDP ?? 0))
                    diagnosticRow("UDP 드롭", String(adapter.tunnelMetrics?.udpDrops ?? 0))
                    if let caps = adapter.tunnelMetrics?.capabilities {
                        diagnosticRow("IPv6", caps.supports(.tcp6) ? "사용 가능" : "사용 불가")
                        diagnosticRow("TTL / Hop Limit", "\(caps.ipv4TTL == 0 ? "기본" : String(caps.ipv4TTL)) / \(caps.ipv6HopLimit == 0 ? "기본" : String(caps.ipv6HopLimit))")
                        diagnosticRow("DNS 차단", caps.policyFlags & 1 != 0 ? "켜짐" : "꺼짐")
                        diagnosticRow("속도 제한", caps.policyFlags & 2 != 0 ? "켜짐" : "꺼짐")
                    }
                }.padding(14)
            }
            settingsSection("앱 관리", subtitle: "연결에 필요한 Mac 네트워크 도구를 관리해요.") {
                settingsButton("네트워크 도구 제거…", symbol: "trash", destructive: true) { confirmRemoval = true }
            }
            Text("DroidBridge · USB 인터넷 공유")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        }
    }

    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private var isPairing: Bool { if case .pairing = adapter.state { return true }; return false }
    private var carrierName: String? {
        if let carrier = adapter.tunnelMetrics?.carrierName, !carrier.isEmpty { return carrier }
        if case .relayReady(let health) = adapter.state, !health.carrierName.isEmpty { return health.carrierName }
        return nil
    }
    private var deviceText: String {
        switch adapter.state {
        case .deviceMissing, .idle: "연결되지 않음"
        case .deviceSelectionRequired: "선택 필요"
        default: adapter.pairedDeviceName ?? "Android · USB"
        }
    }
    private var cellularText: String {
        if let metrics = adapter.tunnelMetrics, metrics.tunnelActive {
            return metrics.cellularAvailable ? (carrierName ?? "사용 가능") : "확인 필요"
        }
        if case .relayReady(let health) = adapter.state {
            return health.isCellularReady ? (carrierName ?? "사용 가능") : "확인 필요"
        }
        return "연결할 때 확인"
    }

    private func performPrimaryAction() {
        guard !actionRunning else { return }
        let action = presentation.action
        actionRunning = true
        Task { @MainActor in
            defer { actionRunning = false }
            switch action {
            case .pair: await adapter.pair()
            case .connect:
                await adapter.prepareRelay()
                if adapter.canStartTunnel { await adapter.startTunnel() }
            case .disconnect: await adapter.disconnect()
            case .refresh: await adapter.refresh(); await adapter.refreshTunnelStatus()
            case .none: break
            }
        }
    }

    private func infoRow(_ symbol: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 24)
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.trailing)
        }.padding(.vertical, 9)
    }

    private func trafficTile(_ title: String, symbol: String, bytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(HostConnectionPresentation.byteCount(bytes)).font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit().lineLimit(1).minimumScaleFactor(0.75)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }

    private func settingsSection<Content: View>(_ title: String, subtitle: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            VStack(spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
        }
    }
    private func settingsButton(_ title: String, symbol: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
            }.font(.system(size: 12)).padding(14).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(destructive ? accent : Color.primary)
        .disabled(actionRunning || adapter.helperOperationInProgress || isPairing)
    }
    private func diagnosticRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().textSelection(.enabled)
        }.font(.system(size: 12))
    }
}

private struct ConnectionActionButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.white)
            .padding(.vertical, 5)
            .background(color.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.4),
                        in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}
