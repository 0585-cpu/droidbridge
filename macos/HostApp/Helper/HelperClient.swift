import DroidBridgeShared
import Foundation

public enum HelperClientError: LocalizedError {
    case unavailable
    case rejected(String)
    case invalidStatus

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "the privileged helper is unavailable"
        case let .rejected(message):
            return message
        case .invalidStatus:
            return "the helper returned an invalid status payload"
        }
    }
}

private final class XPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func once(_ body: () -> Void) {
        let shouldRun = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldRun { body() }
    }
}

public final class HelperClient: @unchecked Sendable {
    private let helperRequirement: String
    private let installer: ManualHelperInstaller

    public init(teamID: String? = RuntimeSigningIdentity.teamID()) {
        let resolvedTeamID = teamID ?? "UNSIGNEDBUILD"
        helperRequirement = HelperCodeRequirement.string(
            teamID: resolvedTeamID,
            bundleID: "io.droidbridge.helper"
        )
        installer = ManualHelperInstaller(teamID: resolvedTeamID)
    }

    public func install() async throws {
        if await installationStatus(), installer.installedHelperMatchesEmbedded() { return }
        try await installer.install()
        for _ in 0..<30 {
            if await installationStatus(), installer.installedHelperMatchesEmbedded() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HelperClientError.unavailable
    }

    public func uninstall() async throws {
        // An explicit helper Stop is the only supported operation that releases
        // a retained route/PF journal. Removal never bypasses that transition.
        if await helperReachable() {
            try await stop()
        }
        try await installer.uninstall()
    }

    public func start(config: TunnelRuntimeConfiguration, secret: Data) async throws {
        let payload = try JSONEncoder.droidBridge.encode(config)
        let connection = makeConnection()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.once { continuation.resume(throwing: error) }
            }) as? DroidBridgeHelperProtocol else {
                continuation.resume(throwing: HelperClientError.unavailable)
                return
            }
            proxy.startTunnel(configJSON: payload, secret: secret) { success, message in
                gate.once {
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: HelperClientError.rejected(message ?? "the helper rejected tunnel startup")
                        )
                    }
                }
            }
        }
    }

    public func stop() async throws {
        let connection = makeConnection()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.once { continuation.resume(throwing: error) }
            }) as? DroidBridgeHelperProtocol else {
                continuation.resume(throwing: HelperClientError.unavailable)
                return
            }
            proxy.stopTunnel { success in
                gate.once {
                    success
                        ? continuation.resume()
                        : continuation.resume(throwing: HelperClientError.rejected("the helper retained fail-closed protection because teardown failed"))
                }
            }
        }
    }

    public func reconnect() async throws {
        let connection = makeConnection()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.once { continuation.resume(throwing: error) }
            }) as? DroidBridgeHelperProtocol else {
                continuation.resume(throwing: HelperClientError.unavailable)
                return
            }
            proxy.reconnectTunnel { success, message in
                gate.once {
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: HelperClientError.rejected(
                                message ?? "the helper rejected the reconnect request"
                            )
                        )
                    }
                }
            }
        }
    }

    public func status() async -> TunnelMetricsSnapshot? {
        let connection = makeConnection()
        defer { connection.invalidate() }

        return await withCheckedContinuation { continuation in
            let gate = XPCReplyGate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.once { continuation.resume(returning: nil) }
            }) as? DroidBridgeHelperProtocol else {
                continuation.resume(returning: nil)
                return
            }
            proxy.status { data in
                gate.once {
                    continuation.resume(
                        returning: try? JSONDecoder().decode(TunnelMetricsSnapshot.self, from: data)
                    )
                }
            }
        }
    }

    private func installationStatus() async -> Bool {
        let connection = makeConnection()
        defer { connection.invalidate() }
        let expectedVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? ""

        return await withCheckedContinuation { continuation in
            let gate = XPCReplyGate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.once { continuation.resume(returning: false) }
            }) as? DroidBridgeHelperProtocol else {
                continuation.resume(returning: false)
                return
            }
            proxy.installStatus { installed in
                guard installed else {
                    gate.once { continuation.resume(returning: false) }
                    return
                }
                proxy.helperVersion { version in
                    gate.once {
                        continuation.resume(
                            returning: !expectedVersion.isEmpty && version == expectedVersion
                        )
                    }
                }
            }
        }
    }

    private func helperReachable() async -> Bool {
        let connection = makeConnection()
        defer { connection.invalidate() }
        return await withCheckedContinuation { continuation in
            let gate = XPCReplyGate()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.once { continuation.resume(returning: false) }
            }) as? DroidBridgeHelperProtocol else {
                continuation.resume(returning: false)
                return
            }
            proxy.installStatus { installed in
                gate.once { continuation.resume(returning: installed) }
            }
        }
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: HelperCodeRequirement.machServiceName,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(with: DroidBridgeHelperProtocol.self)
        connection.setCodeSigningRequirement(helperRequirement)
        connection.activate()
        return connection
    }
}
