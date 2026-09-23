import DroidBridgeShared
import Foundation

private struct HelperDbpConnection: DbpConnection {
    let transport: any RelayTransport

    func send(_ data: Data) async throws { try await transport.send(data) }
    func receiveExactly(_ count: Int) async throws -> Data {
        try await transport.receiveExactly(count)
    }
    func close() async { await transport.cancel() }
}

enum HelperServiceError: LocalizedError {
    case alreadyRunning
    case recoveryRequired
    case invalidSecretLength
    case engineInitialization
    case rollback(original: Error, rollback: Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "the tunnel is already running"
        case .recoveryRequired:
            return "a retained fail-closed state must be stopped before starting a new tunnel"
        case .invalidSecretLength:
            return "the pairing secret must be exactly 32 bytes"
        case .engineInitialization:
            return "the packet engine could not be initialized"
        case let .rollback(original, rollback):
            return "startup failed: \(original.localizedDescription); fail-closed rollback needs attention: \(rollback.localizedDescription)"
        }
    }
}

/// Privileged XPC endpoint that owns fail-closed tunnel lifecycle state.
final class HelperService: NSObject, NSXPCListenerDelegate, DroidBridgeHelperProtocol, @unchecked Sendable {
    let peerRequirement: String
    private let stateLock = NSLock()
    private let pfController: PfController
    private let networkService: NetworkServicePublisher
    private let recoveryStore: HelperRecoveryStateStore
    private var utun: UtunDevice?
    private var tunnelController: TunnelController?
    private var healthTask: Task<Void, Never>?
    private var healthGeneration: UInt64 = 0
    private var healthConfiguration: TunnelRuntimeConfiguration?
    private var healthSecret: Data?
    private var lastHealth: RelayHealth?
    private var runtimeStatus: TunnelRuntimeStatus = .stopped
    private var recoveryAttentionRequired = false

    init(
        teamID: String? = RuntimeSigningIdentity.teamID(),
        bundleID: String = "io.droidbridge.macos",
        pfController: PfController = PfController(),
        networkService: NetworkServicePublisher = NetworkServicePublisher(),
        recoveryStore: HelperRecoveryStateStore = HelperRecoveryStateStore()
    ) {
        peerRequirement = HelperCodeRequirement.string(
            teamID: teamID ?? "UNSIGNEDBUILD",
            bundleID: bundleID
        )
        self.pfController = pfController
        self.networkService = networkService
        self.recoveryStore = recoveryStore
        super.init()
    }

    /// Adopts state left by a killed or crashed helper before accepting XPC.
    /// It deliberately does not touch the network service or PF: only an explicit Stop may
    /// release a retained fail-closed state.
    func reconcilePersistedState() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        do {
            guard let state = try recoveryStore.load() else {
                recoveryAttentionRequired = false
                return
            }
            if let token = state.pfEnableToken {
                try pfController.adoptRecoveryToken(token)
            }
            recoveryAttentionRequired = true
            runtimeStatus = .teardownFailed
        } catch {
            recoveryAttentionRequired = true
            runtimeStatus = .teardownFailed
            throw error
        }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validate(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: DroidBridgeHelperProtocol.self)
        connection.exportedObject = self
        connection.activate()
        return true
    }

    /// The listener enforces `peerRequirement` before this delegate is called. Reject
    /// connections that do not identify a live client process as an additional guard.
    func validate(_ connection: NSXPCConnection) -> Bool {
        connection.processIdentifier > 1
    }

    func installStatus(reply: @escaping (Bool) -> Void) {
        reply(RuntimeSigningIdentity.teamID() != nil)
    }

    func helperVersion(reply: @escaping (String) -> Void) {
        reply(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    }

    func startTunnel(
        configJSON: Data,
        secret: Data,
        reply: @escaping (Bool, String?) -> Void
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }

        var device: UtunDevice?
        var controller: TunnelController?
        do {
            guard utun == nil, tunnelController == nil else {
                throw HelperServiceError.alreadyRunning
            }
            guard !recoveryAttentionRequired,
                  !recoveryStore.hasPersistedState,
                  !pfController.isEnabled,
                  !networkService.isPublished
            else {
                throw HelperServiceError.recoveryRequired
            }
            guard secret.count == 32 else {
                throw HelperServiceError.invalidSecretLength
            }
            let configuration = try JSONDecoder().decode(
                TunnelRuntimeConfiguration.self,
                from: configJSON
            )

            let openedDevice = try UtunDevice()
            device = openedDevice
            try openedDevice.assignAddress()
            let physicalInterfaces = try NetworkInterfaces.physical()

            // Journal intent before loading PF so every subsequent crash can be
            // surfaced as a retained state requiring an explicit Stop.
            try recoveryStore.save(
                HelperRecoveryState(utun: openedDevice.interfaceName, pfEnableToken: nil)
            )

            // Fail-closed invariant: protection is active before traffic moves.
            try pfController.enable(
                utun: openedDevice.interfaceName,
                physical: physicalInterfaces
            )
            guard let pfEnableToken = pfController.recoveryToken else {
                throw HelperServiceError.engineInitialization
            }
            try recoveryStore.save(
                HelperRecoveryState(utun: openedDevice.interfaceName, pfEnableToken: pfEnableToken)
            )

            // Then hand the default route and the system resolver to configd by
            // making the tunnel the primary network. configd keeps them on utun
            // across network changes; a `route add` behind its back does not survive.
            try networkService.publish(utun: openedDevice.interfaceName)

            let runningController = Self.makeTunnelController(
                device: openedDevice,
                configuration: configuration,
                secret: secret
            )
            controller = runningController
            guard runningController.start() else {
                throw HelperServiceError.engineInitialization
            }

            utun = openedDevice
            tunnelController = runningController
            healthConfiguration = configuration
            healthSecret = secret
            runtimeStatus = .running
            beginHealthMonitoringLocked(
                configuration: configuration,
                secret: secret,
                immediately: false
            )
            reply(true, nil)
        } catch {
            controller?.stop()
            if let device {
                do {
                    // Reverse ordering is equally important: service first, protection last.
                    try networkService.withdraw()
                    try pfController.disable()
                    try recoveryStore.remove()
                    device.close()
                } catch let rollbackError {
                    utun = device
                    tunnelController = nil
                    let combined = HelperServiceError.rollback(
                        original: error,
                        rollback: rollbackError
                    )
                    NSLog("DroidBridge fail-closed startup rollback: %@", combined.localizedDescription)
                    reply(false, combined.localizedDescription)
                    return
                }
            }
            NSLog("DroidBridge startTunnel failed: %@", error.localizedDescription)
            reply(false, error.localizedDescription)
        }
    }

    func reconnectTunnel(reply: @escaping (Bool, String?) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard tunnelController != nil,
              let configuration = healthConfiguration,
              let secret = healthSecret
        else {
            reply(false, "there is no active tunnel to reconnect")
            return
        }
        runtimeStatus = .reconnecting
        beginHealthMonitoringLocked(
            configuration: configuration,
            secret: secret,
            immediately: true
        )
        reply(true, nil)
    }

    func status(reply: @escaping (Data) -> Void) {
        stateLock.lock()
        let cellularReady = runtimeStatus == .running
        let snapshot = TunnelMetricsSnapshot(
            activeFlows: tunnelController?.activeFlowCount ?? 0,
            uploadedBytes: lastHealth?.uploadedBytes ?? 0,
            downloadedBytes: lastHealth?.downloadedBytes ?? 0,
            carrierName: lastHealth?.carrierName,
            cellularAvailable: cellularReady,
            tunnelActive: utun != nil || tunnelController != nil
                || networkService.isPublished || pfController.isEnabled
                || recoveryStore.hasPersistedState || recoveryAttentionRequired,
            runtimeStatus: runtimeStatus
        )
        stateLock.unlock()
        reply((try? JSONEncoder.droidBridge.encode(snapshot)) ?? Data())
    }

    func stopTunnel(reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        healthGeneration &+= 1
        healthTask?.cancel()
        healthTask = nil
        tunnelController?.stop()
        do {
            if recoveryStore.hasPersistedState {
                try restorePersistedStateLocked()
            } else {
                // Defensive fallback for an in-memory transaction whose journal
                // could not be created. The service still precedes PF teardown.
                try networkService.withdraw()
                try pfController.disable()
            }
            utun?.close()
            utun = nil
            tunnelController = nil
            healthConfiguration = nil
            if var secret = healthSecret {
                secret.resetBytes(in: 0..<secret.count)
            }
            healthSecret = nil
            lastHealth = nil
            recoveryAttentionRequired = false
            runtimeStatus = .stopped
            reply(true)
        } catch {
            runtimeStatus = .teardownFailed
            NSLog("DroidBridge fail-closed stop retained protection: %@", error.localizedDescription)
            reply(false)
        }
    }

    private func restorePersistedStateLocked() throws {
        guard let state = try recoveryStore.load() else { return }

        // Idempotent, so it also covers a crash before or during publishing.
        try networkService.withdraw()

        if let token = state.pfEnableToken {
            if !pfController.isEnabled {
                try pfController.adoptRecoveryToken(token)
            }
            // A failed -X keeps the token and journal so Stop can be retried.
            try pfController.disable()
        } else if pfController.isEnabled {
            // The current process may have enabled PF successfully but failed
            // to persist the returned token. Keep using the in-memory token;
            // a failed release leaves both it and the journal retryable.
            try pfController.disable()
        } else {
            // The helper may have died after loading the anchor but before
            // persisting the enable token. A fresh process has no token to
            // release, so it can only remove this app's anchor rules.
            try pfController.clearAnchorRules()
        }
        try recoveryStore.remove()
        recoveryAttentionRequired = false
    }

    private func beginHealthMonitoringLocked(
        configuration: TunnelRuntimeConfiguration,
        secret: Data,
        immediately: Bool
    ) {
        healthGeneration &+= 1
        let generation = healthGeneration
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            await self?.monitorRelay(
                configuration: configuration,
                secret: secret,
                generation: generation,
                immediately: immediately
            )
        }
    }

    private func monitorRelay(
        configuration: TunnelRuntimeConfiguration,
        secret: Data,
        generation: UInt64,
        immediately: Bool
    ) async {
        let retryDelays = [1, 2, 4]
        var retryIndex = 0
        var probeImmediately = immediately

        while !Task.isCancelled {
            if !probeImmediately {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
            probeImmediately = false

            do {
                let health = try await Self.probeHealth(
                    configuration: configuration,
                    secret: secret
                )
                guard applyHealthyRelay(health, generation: generation) else { return }
                retryIndex = 0
            } catch {
                if Task.isCancelled { return }
                let cellularFailure = (error as? DroidBridgeError) == .cellularUnavailable
                guard blockDataPlane(
                    cellularFailure: cellularFailure,
                    generation: generation
                ) else { return }

                guard retryIndex < retryDelays.count else {
                    markPersistentBlock(
                        cellularFailure: cellularFailure,
                        generation: generation
                    )
                    return
                }
                let delay = retryDelays[retryIndex]
                retryIndex += 1
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
                guard markReconnecting(generation: generation) else { return }
                probeImmediately = true
            }
        }
    }

    private static func probeHealth(
        configuration: TunnelRuntimeConfiguration,
        secret: Data
    ) async throws -> RelayHealth {
        let client = RelayControlClient(secret: secret) {
            let transport = NWConnectionTransport(
                host: configuration.relayHost,
                port: configuration.relayPort
            )
            try await transport.start()
            return HelperDbpConnection(transport: transport)
        }
        return try await client.health()
    }

    private func applyHealthyRelay(_ health: RelayHealth, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard generation == healthGeneration, tunnelController != nil else { return false }
            if runtimeStatus != .running {
                guard let utun,
                      let healthConfiguration,
                      let healthSecret
                else { return false }
                // A fresh controller isolates late callbacks from flows that
                // belonged to the blocked engine generation.
                let replacement = Self.makeTunnelController(
                    device: utun,
                    configuration: healthConfiguration,
                    secret: healthSecret
                )
                guard replacement.start() else {
                    runtimeStatus = .persistentBlockedRelay
                    return false
                }
                tunnelController = replacement
            }
            lastHealth = health
            runtimeStatus = .running
            return true
        }
    }

    private func blockDataPlane(cellularFailure: Bool, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard generation == healthGeneration, let tunnelController else { return false }
            tunnelController.stop()
            runtimeStatus = cellularFailure ? .blockedCellular : .blockedRelay
            return true
        }
    }

    private func markReconnecting(generation: UInt64) -> Bool {
        stateLock.withLock {
            guard generation == healthGeneration, tunnelController != nil else { return false }
            runtimeStatus = .reconnecting
            return true
        }
    }

    private func markPersistentBlock(cellularFailure: Bool, generation: UInt64) {
        stateLock.withLock {
            guard generation == healthGeneration, tunnelController != nil else { return }
            runtimeStatus = cellularFailure
                ? .persistentBlockedCellular
                : .persistentBlockedRelay
        }
    }

    private static func makeTunnelController(
        device: UtunDevice,
        configuration: TunnelRuntimeConfiguration,
        secret: Data
    ) -> TunnelController {
        TunnelController(
            packetSource: UtunPacketSource(device),
            secret: secret,
            relayHost: configuration.relayHost,
            relayPort: configuration.relayPort,
            maximumFlows: configuration.maximumFlows
        )
    }
}
