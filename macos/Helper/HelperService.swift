import DroidBridgeShared
import Foundation

enum HelperServiceError: LocalizedError {
    case alreadyRunning
    case invalidSecretLength
    case engineInitialization
    case rollback(original: Error, rollback: Error)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            return "the tunnel is already running"
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
    private let routeController: RouteController
    private let pfController: PfController
    private var utun: UtunDevice?
    private var tunnelController: TunnelController?

    init(
        teamID: String = "ABCDE12345",
        bundleID: String = "io.droidbridge.macos",
        routeController: RouteController = RouteController(),
        pfController: PfController = PfController()
    ) {
        peerRequirement = HelperCodeRequirement.string(teamID: teamID, bundleID: bundleID)
        self.routeController = routeController
        self.pfController = pfController
        super.init()
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
        reply(true)
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

            // Fail-closed invariant: protection is active before the default route moves.
            try pfController.enable(
                utun: openedDevice.interfaceName,
                physical: physicalInterfaces
            )
            try routeController.setDefault(utun: openedDevice.interfaceName)

            let runningController = TunnelController(
                packetSource: UtunPacketSource(openedDevice),
                secret: secret,
                relayHost: configuration.relayHost,
                relayPort: configuration.relayPort,
                maximumFlows: configuration.maximumFlows
            )
            controller = runningController
            guard runningController.start() else {
                throw HelperServiceError.engineInitialization
            }

            utun = openedDevice
            tunnelController = runningController
            reply(true, nil)
        } catch {
            controller?.stop()
            if let device {
                do {
                    // Reverse ordering is equally important: route first, protection last.
                    try routeController.restore()
                    try pfController.disable()
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
            reply(false, error.localizedDescription)
        }
    }

    func status(reply: @escaping (Data) -> Void) {
        stateLock.lock()
        let snapshot = TunnelMetricsSnapshot(
            activeFlows: tunnelController?.activeFlowCount ?? 0,
            uploadedBytes: 0,
            downloadedBytes: 0,
            carrierName: nil,
            cellularAvailable: tunnelController != nil
        )
        stateLock.unlock()
        reply((try? JSONEncoder.droidBridge.encode(snapshot)) ?? Data())
    }

    func stopTunnel(reply: @escaping (Bool) -> Void) {
        stateLock.lock()
        defer { stateLock.unlock() }

        tunnelController?.stop()
        do {
            // Fail-closed invariant: restore egress before removing its protection.
            try routeController.restore()
            try pfController.disable()
            utun?.close()
            utun = nil
            tunnelController = nil
            reply(true)
        } catch {
            NSLog("DroidBridge fail-closed stop retained protection: %@", error.localizedDescription)
            reply(false)
        }
    }
}
