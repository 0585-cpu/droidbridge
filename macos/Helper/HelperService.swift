import DroidBridgeShared
import Foundation
import OSLog

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
    private let healthLogger = Logger(subsystem: "io.droidbridge", category: "RelayHealth")
    let peerRequirement: String
    private let stateLock = NSLock()
    private let pfController: PfController
    private let networkService: NetworkServicePublisher
    private let underlay: TailscaleUnderlayInterface?
    private let recoveryStore: HelperRecoveryStateStore
    private let stopCoordinator: HelperStopCoordinator
    private let recoveryVerifier: NetworkRecoveryVerifier
    private let healthProbe: @Sendable (TunnelRuntimeConfiguration, Data) async throws -> RelayHealth
    private let healthSleep: @Sendable (Duration) async throws -> Void
    private var rebuildController: (() -> TunnelController)?
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
        underlay: TailscaleUnderlayInterface? = nil,
        recoveryStore: HelperRecoveryStateStore = HelperRecoveryStateStore(),
        stopCoordinator: HelperStopCoordinator = HelperStopCoordinator(),
        recoveryVerifier: NetworkRecoveryVerifier = NetworkRecoveryVerifier(),
        healthProbe: @escaping @Sendable (TunnelRuntimeConfiguration, Data) async throws -> RelayHealth = HelperService.probeHealth,
        healthSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        peerRequirement = HelperCodeRequirement.string(
            teamID: teamID ?? "UNSIGNEDBUILD",
            bundleID: bundleID
        )
        self.pfController = pfController
        self.networkService = networkService
        self.underlay = underlay
        self.recoveryStore = recoveryStore
        self.stopCoordinator = stopCoordinator
        self.recoveryVerifier = recoveryVerifier
        self.healthProbe = healthProbe
        self.healthSleep = healthSleep
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
            guard !stopCoordinator.isPending else { throw HelperServiceError.recoveryRequired }
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
            underlay?.create()

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
            rebuildController = {
                Self.makeTunnelController(device: openedDevice, configuration: configuration, secret: secret)
            }
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
                    underlay?.destroy()
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
        guard !stopCoordinator.isPending, tunnelController != nil,
              let configuration = healthConfiguration,
              let secret = healthSecret
        else {
            reply(false, "there is no active tunnel to reconnect")
            return
        }
        // Health may have recovered after the GUI read a blocked status. Keep the
        // live engine and monitor; marking it reconnecting would start a second engine.
        guard runtimeStatus != .running else {
            reply(true, nil)
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
        // Never queue more status readers behind a stalled lifecycle operation.
        guard stateLock.try() else { reply(Data()); return }
        let cellularReady = runtimeStatus == .running
        let snapshot = TunnelMetricsSnapshot(
            activeFlows: tunnelController?.activeFlowCount ?? 0,
            uploadedBytes: lastHealth?.uploadedBytes ?? 0,
            downloadedBytes: lastHealth?.downloadedBytes ?? 0,
            carrierName: lastHealth?.carrierName,
            cellularAvailable: cellularReady,
            tunnelActive: utun != nil || tunnelController != nil
                || networkService.isPublished || pfController.isEnabled
                || recoveryStore.hasPersistedState || recoveryAttentionRequired || stopCoordinator.isPending,
            runtimeStatus: runtimeStatus,
            activeUDP: tunnelController?.activeUDPCount ?? 0,
            udpDrops: tunnelController?.udpDrops ?? 0,
            capabilities: tunnelController?.capabilities
        )
        stateLock.unlock()
        reply((try? JSONEncoder.droidBridge.encode(snapshot)) ?? Data())
    }

    func stopTunnel(reply: @escaping (Bool) -> Void) {
        // This must precede stateLock: a health callback may already hold it while
        // synchronously stopping a frozen engine. The watchdog has its own queue.
        stopCoordinator.request(work: { [self] in try stopAndRestore() }, reply: reply)
    }

    func resumePendingStop() {
        do { try stopCoordinator.resumeIfRequested { try stopAndRestore() } }
        catch {
            recoveryAttentionRequired = true
            runtimeStatus = .teardownFailed
            NSLog("DroidBridge pending Stop needs retry: %@", error.localizedDescription)
        }
    }

    private func stopAndRestore() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        healthGeneration &+= 1
        healthTask?.cancel()
        healthTask = nil
        rebuildController = nil
        do {
            tunnelController?.stop()
            let state = try recoveryStore.load()
            // An old journal's utun index may have been reused by another VPN.
            // On restart, service ID and virtual gateway/DNS identify our state.
            let interface = utun?.interfaceName
            try networkService.withdraw()
            underlay?.destroy()
            utun?.close()
            // Wait for configd to withdraw our routes and DNS before releasing PF.
            try recoveryVerifier.verifyRouting(utun: interface)
            if let token = state?.pfEnableToken, !pfController.isEnabled {
                try pfController.adoptRecoveryToken(token)
            }
            if pfController.isEnabled { try pfController.disable() }
            else { try pfController.clearAnchorRules() }
            // A verification retry must not try to release an already released token.
            if let state {
                try recoveryStore.save(HelperRecoveryState(utun: state.utun, pfEnableToken: nil))
            }
            try recoveryVerifier.verifyAnchor()
            try recoveryStore.remove()
            utun = nil
            tunnelController = nil
            healthConfiguration = nil
            if var secret = healthSecret { secret.resetBytes(in: 0..<secret.count) }
            healthSecret = nil
            lastHealth = nil
            recoveryAttentionRequired = false
            runtimeStatus = .stopped
        } catch {
            recoveryAttentionRequired = true
            runtimeStatus = .teardownFailed
            throw error
        }
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

    func monitorRelay(
        configuration: TunnelRuntimeConfiguration,
        secret: Data,
        generation: UInt64,
        immediately: Bool
    ) async {
        // With 3 s probes this retains the running session for about a minute of missed health:
        // Samsung's freezer was seen pausing the phone app ~45 s with USB attached, and stopping
        // the engine at ~20 s dropped every flow (Parsec) although the phone came back. pf keeps
        // the session fail-closed meanwhile; matches the USB no-progress deadline (60 s).
        let retryDelays = [1, 2, 4, 8, 15, 15]
        var retryIndex = 0
        var recoveryDelay = 5
        var failureCount = 0
        var probeImmediately = immediately

        while !Task.isCancelled {
            guard canMonitorHealth(generation: generation) else { return }
            if !probeImmediately {
                do { try await healthSleep(.seconds(2)) }
                catch { return }
            }
            probeImmediately = false
            guard !Task.isCancelled, canMonitorHealth(generation: generation) else { return }

            do {
                let health = try await healthProbe(configuration, secret)
                guard !Task.isCancelled, applyHealthyRelay(health, generation: generation) else { return }
                if failureCount > 0 {
                    healthLogger.info("Health probe recovered after \(failureCount) failed attempts")
                }
                retryIndex = 0
                recoveryDelay = 5
                failureCount = 0
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                if failureCount < Int.max { failureCount += 1 }
                let cellularFailure = (error as? DroidBridgeError) == .cellularUnavailable
                let recoverable = Self.canRecoverHealth(error)
                guard handleHealthFailure(
                    error: error,
                    attempt: failureCount,
                    retriesRemain: recoverable && retryIndex < retryDelays.count,
                    cellularFailure: cellularFailure,
                    generation: generation
                ) else { return }

                guard recoverable else {
                    markPersistentBlock(cellularFailure: cellularFailure, generation: generation)
                    return
                }
                let delay: Int
                if retryIndex < retryDelays.count {
                    delay = retryDelays[retryIndex]
                    retryIndex += 1
                } else {
                    // Keep the engine stopped while the phone cannot execute. A later
                    // authenticated HEALTH may rebuild it without requiring a USB reset.
                    delay = recoveryDelay
                    recoveryDelay = min(recoveryDelay * 2, 30)
                    healthLogger.notice("Waiting for relay recovery; next authenticated probe in \(delay) seconds")
                }
                guard markReconnecting(generation: generation) else { return }
                do { try await healthSleep(.seconds(delay)) }
                catch { return }
                probeImmediately = true
            }
        }
    }

    private func canMonitorHealth(generation: UInt64) -> Bool {
        stateLock.withLock {
            generation == healthGeneration && tunnelController != nil && !stopCoordinator.isPending
        }
    }

    private static func canRecoverHealth(_ error: Error) -> Bool {
        guard let error = error as? DroidBridgeError else { return true } // Transport errors.
        switch error {
        case .relayTimedOut, .relayAppNotRunning, .cellularUnavailable: return true
        case .relayProtocol(let message):
            // NWConnectionTransport uses these exact local errors for EOF before
            // a complete control frame. Retry the authenticated exchange; malformed
            // frames and failed authentication must still stop recovery.
            return message == "peer closed" || message == "truncated frame"
        default: return false // Authentication, protocol and configuration failures need intervention.
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
            guard generation == healthGeneration, tunnelController != nil, !stopCoordinator.isPending else { return false }
            if runtimeStatus != .running {
                guard let rebuildController else { return false }
                // A fresh controller isolates late callbacks from flows that
                // belonged to the blocked engine generation.
                let replacement = rebuildController()
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

    private func handleHealthFailure(error: Error, attempt: Int, retriesRemain: Bool,
                                     cellularFailure: Bool, generation: UInt64) -> Bool {
        stateLock.withLock {
            guard generation == healthGeneration, let tunnelController, !stopCoordinator.isPending else { return false }
            let reason: String
            switch error {
            case DroidBridgeError.relayTimedOut: reason = "deadline"
            case DroidBridgeError.cellularUnavailable: reason = "cellular-unavailable"
            case DroidBridgeError.relayAuthenticationFailed: reason = "authentication"
            case DroidBridgeError.relayProtocol: reason = "protocol"
            default: reason = "transport"
            }
            // One missing status reply does not invalidate the existing authenticated
            // data sockets. Keep their owner and running status through bounded retry.
            // Explicit failures and an exhausted deadline budget still fail closed.
            if (error as? DroidBridgeError) == .relayTimedOut,
               retriesRemain, runtimeStatus == .running {
                healthLogger.notice("Health probe failed: reason=\(reason, privacy: .public) attempt=\(attempt) action=retain")
                return true
            }
            healthLogger.notice("Health probe failed: reason=\(reason, privacy: .public) attempt=\(attempt) action=block")
            tunnelController.stop()
            runtimeStatus = cellularFailure ? .blockedCellular : .blockedRelay
            return true
        }
    }

    private func markReconnecting(generation: UInt64) -> Bool {
        stateLock.withLock {
            guard generation == healthGeneration, tunnelController != nil, !stopCoordinator.isPending else { return false }
            // A retained session must stay running, or healthy recovery would replace it.
            if runtimeStatus != .running { runtimeStatus = .reconnecting }
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

    #if DROIDBRIDGE_HELPER_CHECKS
    // Test-only lifecycle fixture; excluded from the privileged helper binary.
    func seedRelayForChecks(_ controller: TunnelController, configuration: TunnelRuntimeConfiguration,
                            status: TunnelRuntimeStatus, rebuild: (() -> TunnelController)? = nil) {
        stateLock.withLock {
            tunnelController = controller
            rebuildController = rebuild
            healthConfiguration = configuration
            healthSecret = Data(count: 32)
            runtimeStatus = status
        }
    }

    var healthGenerationForChecks: UInt64 { stateLock.withLock { healthGeneration } }
    #endif
}
