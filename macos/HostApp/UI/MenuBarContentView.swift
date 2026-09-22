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
                DevicePickerView(devices: devices) { _ in }
            case .pairing(let sas):
                PairingApprovalView(sas: sas, onApprove: {}, onReject: {})
            case .relayReady(let health):
                VStack(alignment: .leading) {
                    Text("Carrier: \(health.carrierName)")
                    Text("Cellular: \(health.isCellularReady ? "available" : "unavailable")")
                    Text("Flows: \(health.activeSessions)/\(health.maximumSessions)")
                    Text("↑\(health.uploadedBytes)  ↓\(health.downloadedBytes)")
                }.font(.caption)
            default:
                EmptyView()
            }

            if let metrics = adapter.tunnelMetrics {
                VStack(alignment: .leading) {
                    Text(adapter.tunnelRunning ? "Tunnel: connected" : "Tunnel: stopped")
                    Text("Active flows: \(metrics.activeFlows)")
                }
                .font(.caption)
            }

            Divider()
            HStack {
                Button("Start Tunnel") { Task { await adapter.startTunnel() } }
                    .disabled(adapter.tunnelRunning)
                Button("Stop Tunnel") { Task { await adapter.stopTunnel() } }
                    .disabled(!adapter.tunnelRunning)
            }
            HStack {
                Button("Refresh") { Task { await adapter.refresh() } }
                Button("Disconnect") { Task { await adapter.disconnect() } }
            }
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 280)
        .task {
            await adapter.refresh()
            await adapter.refreshTunnelStatus()
        }
    }
}
