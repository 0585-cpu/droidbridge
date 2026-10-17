import Foundation

/// Testable host state machine. Owns the fail-closed transitions; the UI adapter observes `state`.
/// It removes only its transport's local services and keeps the pairing secret until `forget`.
public actor DroidBridgeCoordinatorCore {
    public private(set) var state: HostAppState
    private let adb: any RelayForwarding
    private let secretStore: any PairingSecretStore
    private var preparedSerial: String?

    public init(state: HostAppState = .idle, adb: any RelayForwarding, secretStore: any PairingSecretStore,
                preparedSerial: String? = nil) {
        self.state = state
        self.adb = adb
        self.secretStore = secretStore
        self.preparedSerial = preparedSerial
    }

    /// Recompute state from the current device list. If a prepared device disappears, tear down its
    /// forwards (fail closed) but keep the pairing.
    public func deviceSnapshotChanged(_ devices: [AdbDevice]) async {
        if let prepared = preparedSerial {
            guard devices.contains(where: { $0.serial == prepared && $0.state == .authorized }) else {
                await teardownForwards(serial: prepared)
                preparedSerial = nil
                state = .deviceMissing
                return
            }
            // Health/metrics are more informative than a generic device-ready state while the
            // prepared USB endpoint is still present.
            return
        }

        let authorized = devices.filter { $0.state == .authorized }
        if devices.isEmpty {
            state = .deviceMissing
        } else if authorized.isEmpty {
            if let unauthorized = devices.first(where: { $0.state == .unauthorized }) {
                state = .deviceUnauthorized(serial: unauthorized.serial)
            } else {
                state = .deviceMissing
            }
        } else if authorized.count > 1 {
            state = .deviceSelectionRequired(authorized)
        } else {
            state = .deviceReady(authorized[0])
        }
    }

    public func selectDevice(_ serial: String, from devices: [AdbDevice]) {
        guard let device = devices.first(where: { $0.serial == serial && $0.state == .authorized }) else { return }
        state = .deviceReady(device)
    }

    public func deviceSelected(_ device: AdbDevice) {
        guard device.state == .authorized else { return }
        state = .deviceReady(device)
    }

    public func beginPairing() { state = .pairing(sas: nil) }

    public func showPairingCode(_ sas: String) {
        guard case .pairing = state else { return }
        state = .pairing(sas: sas)
    }

    public func beginRelayPreparation() { state = .relayPreparing }

    /// Marks relay prepared (forwards exist) and publishes health.
    public func relayPrepared(serial: String, health: RelayHealth) {
        preparedSerial = serial
        state = .relayReady(health: health)
    }

    /// User-initiated Disconnect: remove forwards, keep the secret.
    public func disconnect() async {
        if let prepared = preparedSerial { await teardownForwards(serial: prepared) }
        preparedSerial = nil
        state = .idle
    }

    /// Explicit Forget: disconnect and delete the secret.
    public func forget(peerId: String) async {
        await disconnect()
        try? secretStore.delete(peerId: peerId)
    }

    public func setFailed(_ message: String) { state = .failed(message) }

    private func teardownForwards(serial: String) async {
        try? await adb.removeForward(serial: serial, hostPort: RelayPreparer.relayPort)
        try? await adb.removeForward(serial: serial, hostPort: RelayPreparer.pairingPort)
    }
}
