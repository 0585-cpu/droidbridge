import Foundation
import Observation
import DroidBridgeShared

private struct HostDbpConnection: DbpConnection {
    let transport: any RelayTransport

    func send(_ data: Data) async throws { try await transport.send(data) }
    func receiveExactly(_ count: Int) async throws -> Data {
        try await transport.receiveExactly(count)
    }
    func close() async { await transport.cancel() }
}

private struct HostRelayHealthClient: RelayHealthChecking {
    let client: RelayControlClient

    func health(secret: Data) async throws -> RelayHealth {
        try await client.health()
    }
}

/// Main-actor bridge between the testable shared state machine and SwiftUI. It owns only user-flow
/// orchestration; protocol parsing and privileged network mutations remain in Shared/the helper.
@MainActor
@Observable
public final class DroidBridgeCoordinatorAdapter {
    public private(set) var state: HostAppState = .idle
    public private(set) var pairedDeviceName: String?
    public private(set) var tunnelMetrics: TunnelMetricsSnapshot?
    public private(set) var tunnelRunning = false
    public private(set) var tunnelMessage: String?
    public private(set) var helperOperationInProgress = false

    private let core: DroidBridgeCoordinatorCore
    private let devices: () async -> [AdbDevice]
    private let adb: any RelayAdb
    private let helper: HelperClient
    private let configStore: any RuntimeConfigurationStore
    private let secretStore: any PairingSecretStore

    private var deviceSnapshot: [AdbDevice] = []
    private var selectedDevice: AdbDevice?
    private var pairingApproval: CheckedContinuation<Bool, Never>?
    private var monitorTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?

    public init(
        core: DroidBridgeCoordinatorCore,
        devices: @escaping () async -> [AdbDevice],
        adb: any RelayAdb,
        helper: HelperClient,
        configStore: any RuntimeConfigurationStore,
        secretStore: any PairingSecretStore
    ) {
        self.core = core
        self.devices = devices
        self.adb = adb
        self.helper = helper
        self.configStore = configStore
        self.secretStore = secretStore
    }

    public var canPair: Bool {
        if case .deviceReady = state { return true }
        return false
    }

    public var canPrepareRelay: Bool {
        guard let selectedDevice, let configured = try? configStore.read() else { return false }
        return configured.deviceSerial == selectedDevice.serial
    }

    public var hasPairing: Bool { (try? configStore.read()) != nil }

    public var canStartTunnel: Bool {
        guard !tunnelRunning, !helperOperationInProgress else { return false }
        if case .relayReady = state { return true }
        return false
    }

    public func startMonitoring() {
        guard monitorTask == nil else { return }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    public func refresh() async {
        let snapshot = await devices()
        deviceSnapshot = snapshot

        let selectedStillPresent = selectedDevice.map { selected in
            snapshot.contains(where: { $0.serial == selected.serial && $0.state == .authorized })
        } ?? false
        if selectedDevice != nil, !selectedStillPresent {
            self.selectedDevice = nil
            resolvePairingApproval(false)
        }

        if selectedStillPresent {
            switch state {
            case .pairing, .relayPreparing:
                return
            default:
                break
            }
        }

        await core.deviceSnapshotChanged(snapshot)
        state = await core.state

        let authorized = snapshot.filter { $0.state == .authorized }
        if authorized.count == 1 {
            selectedDevice = authorized[0]
        } else if let configured = try? configStore.read(),
                  let match = authorized.first(where: { $0.serial == configured.deviceSerial }) {
            selectedDevice = match
            await core.deviceSelected(match)
            state = await core.state
        }
    }

    public func selectDevice(_ device: AdbDevice) async {
        guard deviceSnapshot.contains(device), device.state == .authorized else { return }
        selectedDevice = device
        await core.selectDevice(device.serial, from: deviceSnapshot)
        state = await core.state
    }

    /// Starts the Mac side after the user has opened "Pair New Mac" on Android. Connection attempts
    /// are retried during the Android 60-second pairing window, so button ordering is not fragile.
    public func pair() async {
        guard let device = selectedDevice else {
            tunnelMessage = "Select an authorized Android device first."
            return
        }
        resolvePairingApproval(false)
        tunnelMessage = "On Android, tap Pair New Mac, then compare the code."
        await core.beginPairing()
        state = await core.state

        do {
            try await adb.forward(
                serial: device.serial,
                hostPort: RelayPreparer.pairingPort,
                devicePort: RelayPreparer.pairingPort
            )
            try? await adb.startActivity(serial: device.serial, component: RelayPreparer.activity)

            let client = PairingClient(
                connectionFactory: { try await Self.connectForPairing() },
                store: secretStore
            )
            let result = try await client.pair(
                peerId: Self.localPeerID,
                displayName: Host.current().localizedName ?? "Mac"
            ) { [weak self] sas in
                guard let self else { return false }
                return await self.requestPairingApproval(sas)
            }

            try await adb.removeForward(serial: device.serial, hostPort: RelayPreparer.pairingPort)
            let configuration = try TunnelRuntimeConfiguration(
                deviceSerial: device.serial,
                relayHost: TunnelRuntimeConfiguration.loopback,
                relayPort: TunnelRuntimeConfiguration.relayPortB1,
                pairedPeerId: result.peerId,
                keychainAccount: result.peerId,
                maximumFlows: 128
            )
            do {
                try configStore.write(configuration)
            } catch {
                try? secretStore.delete(peerId: result.peerId)
                throw error
            }
            pairedDeviceName = result.displayName
            tunnelMessage = "Paired. Start the Android relay, then prepare it."
            await core.deviceSelected(device)
            state = await core.state
        } catch {
            resolvePairingApproval(false)
            try? await adb.removeForward(serial: device.serial, hostPort: RelayPreparer.pairingPort)
            tunnelMessage = error.localizedDescription
            await core.setFailed(error.localizedDescription)
            state = await core.state
        }
    }

    public func approvePairing() { resolvePairingApproval(true) }
    public func rejectPairing() { resolvePairingApproval(false) }

    public func prepareRelay() async {
        guard let device = selectedDevice else {
            tunnelMessage = "Select the paired Android device first."
            return
        }
        do {
            guard let configuration = try configStore.read(),
                  configuration.deviceSerial == device.serial else {
                throw DroidBridgeError.invalidConfiguration("pair this Android device first")
            }
            guard var secret = try secretStore.load(peerId: configuration.keychainAccount) else {
                throw DroidBridgeError.invalidConfiguration("the pairing secret is missing")
            }
            defer { secret.resetBytes(in: 0..<secret.count) }

            tunnelMessage = "Starting the Android relay and checking cellular access…"
            await core.beginRelayPreparation()
            state = await core.state

            let health = RelayControlClient(
                secret: secret,
                connectionFactory: {
                    let transport = NWConnectionTransport(
                        host: configuration.relayHost,
                        port: configuration.relayPort
                    )
                    try await transport.start()
                    return HostDbpConnection(transport: transport)
                }
            )
            let preparation = try await RelayPreparer(
                adb: adb,
                healthClient: HostRelayHealthClient(client: health)
            )
                .prepare(device: device, secret: secret)
            tunnelMessage = nil
            await core.relayPrepared(serial: device.serial, health: preparation.health)
            state = await core.state
        } catch {
            tunnelMessage = error.localizedDescription
            await core.setFailed(error.localizedDescription)
            state = await core.state
        }
    }

    public func forgetPairing() async {
        guard !helperOperationInProgress else { return }
        if tunnelRunning { await stopTunnel() }
        guard !tunnelRunning else { return }
        if let configuration = try? configStore.read() {
            await core.forget(peerId: configuration.keychainAccount)
        } else {
            await core.disconnect()
        }
        try? configStore.delete()
        pairedDeviceName = nil
        tunnelMessage = nil
        await refresh()
    }

    public func disconnect() async {
        guard !helperOperationInProgress else { return }
        if tunnelRunning {
            await stopTunnel()
            guard !tunnelRunning else { return }
        }
        resolvePairingApproval(false)
        await core.disconnect()
        state = await core.state
    }

    public func startTunnel() async {
        guard !tunnelRunning, beginHelperOperation() else { return }
        defer { helperOperationInProgress = false }
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
            let message = error.localizedDescription
            tunnelRunning = false
            await refreshTunnelStatus()
            tunnelMessage = message
        }
    }

    public func stopTunnel() async {
        guard beginHelperOperation() else { return }
        defer { helperOperationInProgress = false }
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

    public func reconnectTunnel() async {
        guard beginHelperOperation() else { return }
        defer { helperOperationInProgress = false }
        do {
            try await helper.reconnect()
            tunnelMessage = "Rechecking the cellular relay…"
            startStatusPolling()
        } catch {
            tunnelMessage = error.localizedDescription
        }
    }

    public func uninstallHelper() async {
        guard beginHelperOperation() else { return }
        defer { helperOperationInProgress = false }
        tunnelMessage = "Stopping and removing the privileged helper…"
        do {
            try await helper.uninstall()
            statusTask?.cancel()
            statusTask = nil
            tunnelRunning = false
            tunnelMetrics = nil
            tunnelMessage = "Privileged helper removed."
        } catch {
            await refreshTunnelStatus()
            tunnelMessage = error.localizedDescription
        }
    }

    public func refreshTunnelStatus() async {
        if let metrics = await helper.status() {
            tunnelMetrics = metrics
            tunnelRunning = metrics.tunnelActive
            if tunnelRunning { startStatusPolling() }
        }
    }

    private func requestPairingApproval(_ sas: String) async -> Bool {
        await core.showPairingCode(sas)
        state = await core.state
        tunnelMessage = nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                pairingApproval = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolvePairingApproval(false) }
        }
    }

    private func resolvePairingApproval(_ approved: Bool) {
        let continuation = pairingApproval
        pairingApproval = nil
        continuation?.resume(returning: approved)
    }

    private func beginHelperOperation() -> Bool {
        guard !helperOperationInProgress else {
            tunnelMessage = "Another privileged-helper operation is already in progress."
            return false
        }
        helperOperationInProgress = true
        return true
    }

    private func startStatusPolling() {
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let metrics = await helper.status() {
                    tunnelMetrics = metrics
                    tunnelRunning = metrics.tunnelActive
                    switch metrics.runtimeStatus {
                    case .running:
                        tunnelMessage = nil
                    case .blockedCellular:
                        tunnelMessage = "Cellular unavailable; traffic is blocked fail-closed."
                    case .blockedRelay:
                        tunnelMessage = "USB relay unavailable; traffic is blocked fail-closed."
                    case .reconnecting:
                        tunnelMessage = "Retrying the cellular relay (1/2/4-second backoff)…"
                    case .persistentBlockedCellular:
                        tunnelMessage = "Cellular is still unavailable. Reconnect or stop the tunnel."
                    case .persistentBlockedRelay:
                        tunnelMessage = "USB relay is still unavailable. Reconnect or stop the tunnel."
                    case .teardownFailed:
                        tunnelMessage = "Teardown failed; protection remains active. Retry Stop Tunnel."
                    case .stopped:
                        if metrics.tunnelActive {
                            tunnelMessage = "Tunnel stopped; fail-closed protection may still be active."
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private static func connectForPairing() async throws -> PairingConnection {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        var lastError: Error = DroidBridgeError.pairingTimedOut
        while clock.now < deadline {
            try Task.checkCancellation()
            let connection = NetworkPairingConnection()
            do {
                try await connection.start()
                return connection
            } catch {
                lastError = error
                await connection.close()
                try await Task.sleep(for: .milliseconds(500))
            }
        }
        throw lastError
    }

    private static let localPeerID: String = {
        let defaults = UserDefaults.standard
        let key = "io.droidbridge.local-peer-id"
        if let existing = defaults.string(forKey: key) { return existing }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }()
}
