import Foundation
import DroidBridgeShared

/// Polls relay health on an interval and reports readiness. On failure or "cellular unavailable" it calls
/// `onUnavailable` so the controller can fail closed without removing tunnel settings.
final class RelayHealthMonitor: @unchecked Sendable {
    private let secret: Data
    private let host: String
    private let port: UInt16
    private let interval: Duration
    private let onReady: @Sendable (RelayHealth) -> Void
    private let onUnavailable: @Sendable () -> Void
    private var task: Task<Void, Never>?

    init(secret: Data, host: String = "127.0.0.1", port: UInt16 = 27183, interval: Duration = .seconds(2),
         onReady: @escaping @Sendable (RelayHealth) -> Void,
         onUnavailable: @escaping @Sendable () -> Void) {
        self.secret = secret; self.host = host; self.port = port; self.interval = interval
        self.onReady = onReady; self.onUnavailable = onUnavailable
    }

    func start() {
        let client = RelayControlClient(secret: secret, connectionFactory: {
            let transport = NWConnectionTransport(host: self.host, port: self.port)
            try? await transport.start()
            return NWDbpConnection(transport: transport)
        })
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    let health = try await client.health()
                    if health.isCellularReady { onReady(health) } else { onUnavailable() }
                } catch {
                    onUnavailable()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
}
