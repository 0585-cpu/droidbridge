import DroidBridgeShared
import Foundation

public enum HelperClientError: LocalizedError {
    case unavailable
    case rejected(String)
    case invalidStatus
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            return "the privileged helper is unavailable"
        case let .rejected(message):
            return message
        case .timedOut:
            return "네트워크 복구 응답이 늦어지고 있어요. 연결 해제를 다시 눌러 주세요."
        case .invalidStatus:
            return "the helper returned an invalid status payload"
        }
    }
}

private final class XPCReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func deadline(_ seconds: TimeInterval, _ body: @escaping @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { [self] in once(body) }
    }

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

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: "/Library/PrivilegedHelperTools/io.droidbridge.helper")
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
            gate.deadline(15) { continuation.resume(throwing: HelperClientError.timedOut) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.once { continuation.resume(throwing: error) }
            }) as? DroidBridgeHelperProtocol else {
                gate.once { continuation.resume(throwing: HelperClientError.unavailable) }
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

    @discardableResult
    public func stop() async throws -> Bool {
        try await HelperStopRetry.run { [self] in try await stopAttempt() }
        // An older installed helper can Stop normally but does not verify restoration.
        return installer.installedHelperMatchesEmbedded()
    }

    private func stopAttempt() async throws {
        let connection = makeConnection()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate()
            gate.deadline(3) { continuation.resume(throwing: HelperClientError.timedOut) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.once { continuation.resume(throwing: error) }
            }) as? DroidBridgeHelperProtocol else {
                gate.once { continuation.resume(throwing: HelperClientError.unavailable) }
                return
            }
            proxy.stopTunnel { success in
                gate.once {
                    success
                        ? continuation.resume()
                        : continuation.resume(throwing: HelperClientError.rejected("네트워크 설정 복원을 확인하지 못했어요. 연결 해제를 다시 눌러 주세요."))
                }
            }
        }
    }

    public func reconnect() async throws {
        let connection = makeConnection()
        defer { connection.invalidate() }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = XPCReplyGate()
            gate.deadline(3) { continuation.resume(throwing: HelperClientError.timedOut) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                gate.once { continuation.resume(throwing: error) }
            }) as? DroidBridgeHelperProtocol else {
                gate.once { continuation.resume(throwing: HelperClientError.unavailable) }
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
            gate.deadline(2) { continuation.resume(returning: nil) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.once { continuation.resume(returning: nil) }
            }) as? DroidBridgeHelperProtocol else {
                gate.once { continuation.resume(returning: nil) }
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
            gate.deadline(2) { continuation.resume(returning: false) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.once { continuation.resume(returning: false) }
            }) as? DroidBridgeHelperProtocol else {
                gate.once { continuation.resume(returning: false) }
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
            gate.deadline(2) { continuation.resume(returning: false) }
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                gate.once { continuation.resume(returning: false) }
            }) as? DroidBridgeHelperProtocol else {
                gate.once { continuation.resume(returning: false) }
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
