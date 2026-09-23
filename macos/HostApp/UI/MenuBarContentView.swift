import SwiftUI
import DroidBridgeShared

struct MenuBarContentView: View {
    @Bindable var adapter: DroidBridgeCoordinatorAdapter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DroidBridge").font(.headline)
            Text(adapter.state.statusText).font(.subheadline).foregroundStyle(.secondary)
            if let message = adapter.tunnelMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }

            switch adapter.state {
            case .deviceSelectionRequired(let devices):
                DevicePickerView(devices: devices) { device in
                    Task { await adapter.selectDevice(device) }
                }
            case .deviceReady:
                HStack {
                    Button("Pair New Mac") { Task { await adapter.pair() } }
                    if adapter.hasPairing {
                        Button("Forget Pairing") { Task { await adapter.forgetPairing() } }
                    }
                }
                if adapter.canPrepareRelay {
                    Button("Prepare Relay") { Task { await adapter.prepareRelay() } }
                }
            case .pairing(let sas):
                PairingApprovalView(
                    sas: sas,
                    onApprove: adapter.approvePairing,
                    onReject: adapter.rejectPairing
                )
            case .relayPreparing:
                ProgressView("Checking cellular relay…")
            case .relayReady(let health):
                VStack(alignment: .leading) {
                    Text("Carrier: \(health.carrierName)")
                    Text("Cellular: \(health.isCellularReady ? "available" : "unavailable")")
                    Text("Flows: \(health.activeSessions)/\(health.maximumSessions)")
                    Text("↑\(health.uploadedBytes)  ↓\(health.downloadedBytes)")
                }.font(.caption)
                HStack {
                    Button("Recheck Relay") { Task { await adapter.prepareRelay() } }
                    Button("Forget Pairing") { Task { await adapter.forgetPairing() } }
                }
            default:
                EmptyView()
            }

            if let metrics = adapter.tunnelMetrics {
                VStack(alignment: .leading) {
                    Text("Tunnel: \(metrics.runtimeStatus.displayText)")
                    Text("Active flows: \(metrics.activeFlows) · UDP: \(metrics.activeUDP)")
                    Text("UDP drops: \(metrics.udpDrops)")
                    if let caps = metrics.capabilities {
                        Text("IPv6: \(caps.supports(.tcp6) ? "available" : "blocked") · UDP: \(caps.supports(.udp4) || caps.supports(.udp6) ? "available" : "blocked")")
                        Text("TTL: \(caps.ipv4TTL == 0 ? "default" : String(caps.ipv4TTL)) · Hop Limit: \(caps.ipv6HopLimit == 0 ? "default" : String(caps.ipv6HopLimit))")
                        if caps.policyFlags != 0 { Text("DNS filter: \(caps.policyFlags & 1 != 0 ? "on" : "off") · Rate limits: \(caps.policyFlags & 2 != 0 ? "on" : "off")") }
                    }
                    if let carrier = metrics.carrierName {
                        Text("Carrier: \(carrier)")
                    }
                    Text("↑\(metrics.uploadedBytes)  ↓\(metrics.downloadedBytes)")
                }
                .font(.caption)
            }

            Divider()
            HStack {
                Button("Start Tunnel") { Task { await adapter.startTunnel() } }
                    .disabled(!adapter.canStartTunnel)
                Button("Stop Tunnel") { Task { await adapter.stopTunnel() } }
                    .disabled(!adapter.tunnelRunning || adapter.helperOperationInProgress)
                if adapter.tunnelMetrics?.runtimeStatus.needsManualReconnect == true {
                    Button("Reconnect") { Task { await adapter.reconnectTunnel() } }
                        .disabled(adapter.helperOperationInProgress)
                }
            }
            HStack {
                Button("Refresh") { Task { await adapter.refresh() } }
                Button("Disconnect") { Task { await adapter.disconnect() } }
            }
            Button("Remove Privileged Helper…") {
                Task { await adapter.uninstallHelper() }
            }
            .disabled(adapter.helperOperationInProgress)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 280)
        .task {
            adapter.startMonitoring()
            await adapter.refreshTunnelStatus()
        }
    }
}

private extension TunnelRuntimeStatus {
    var displayText: String {
        switch self {
        case .running: "connected"
        case .blockedRelay, .blockedCellular: "blocked"
        case .reconnecting: "reconnecting"
        case .persistentBlockedRelay, .persistentBlockedCellular: "blocked—action required"
        case .teardownFailed: "teardown failed—retry stop"
        case .stopped: "stopped"
        }
    }

    var needsManualReconnect: Bool {
        switch self {
        case .persistentBlockedRelay, .persistentBlockedCellular: true
        default: false
        }
    }
}
