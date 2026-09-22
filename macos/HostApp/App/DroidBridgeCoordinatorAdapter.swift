import Foundation
import Observation
import DroidBridgeShared

/// @MainActor bridge between the shared `DroidBridgeCoordinatorCore` actor and SwiftUI. Publishes an
/// immutable `HostAppState` the views render; performs no protocol logic itself.
@MainActor
@Observable
public final class DroidBridgeCoordinatorAdapter {
    public private(set) var state: HostAppState = .idle
    public private(set) var pairedMacName: String?
    public private(set) var tunnelMetrics: TunnelMetricsSnapshot?
    public private(set) var tunnelRunning = false
    public private(set) var tunnelMessage: String?

    private let core: DroidBridgeCoordinatorCore
    private let devices: () async -> [AdbDevice]
    private let helper: HelperClient
    private let configStore: any RuntimeConfigurationStore
    private let secretStore: any PairingSecretStore
    private var statusTask: Task<Void, Never>?

    public init(
        core: DroidBridgeCoordinatorCore,
        devices: @escaping () async -> [AdbDevice],
        helper: HelperClient,
        configStore: any RuntimeConfigurationStore,
        secretStore: any PairingSecretStore
    ) {
        self.core = core
        self.devices = devices
        self.helper = helper
        self.configStore = configStore
        self.secretStore = secretStore
    }

    public func refresh() async {
        await core.deviceSnapshotChanged(await devices())
        state = await core.state
    }

    public func disconnect() async {
        if tunnelRunning {
            await stopTunnel()
            guard !tunnelRunning else { return }
        }
        await core.disconnect()
        state = await core.state
    }

    public func startTunnel() async {
        guard !tunnelRunning else { return }
        tunnelMessage = "Installing privileged helper…"
        do {
            guard let configuration = try configStore.read() else {
                throw DroidBridgeError.invalidConfiguration(
                    "pair and prepare the Android relay before starting the tunnel"
                )
            }
            guard var secret = try secretStore.load(peerId: configuration.keychainAccount) else {
                throw DroidBridgeError.invalidConfiguration("the pairing secret is missing")
            }
            defer { secret.resetBytes(in: 0..<secret.count) }

            try await helper.install()
            tunnelMessage = "Starting fail-closed tunnel…"
            try await helper.start(config: configuration, secret: secret)
            tunnelRunning = true
            tunnelMessage = nil
            startStatusPolling()
        } catch {
            tunnelRunning = false
            tunnelMessage = error.localizedDescription
        }
    }

    public func stopTunnel() async {
        do {
            try await helper.stop()
            statusTask?.cancel()
            statusTask = nil
            tunnelRunning = false
            tunnelMetrics = nil
            tunnelMessage = nil
        } catch {
            tunnelRunning = true
            tunnelMessage = error.localizedDescription
        }
    }

    public func refreshTunnelStatus() async {
        if let metrics = await helper.status() {
            tunnelMetrics = metrics
            tunnelRunning = metrics.cellularAvailable
            if tunnelRunning { startStatusPolling() }
        }
    }

    private func startStatusPolling() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let metrics = await helper.status() {
                    tunnelMetrics = metrics
                    tunnelRunning = metrics.cellularAvailable
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
