import Foundation
import NetworkExtension
import DroidBridgeShared

/// NETunnelProviderManager-backed implementation of the shared TunnelPreferences contract. Keeps one
/// configuration for the DroidBridge provider, removing duplicates, and never puts a secret in options.
final class NETunnelPreferences: TunnelPreferences, @unchecked Sendable {
    private static let bundleId = "io.droidbridge.macos.PacketTunnel"
    private let runtimeConfig: Data
    private var manager: NETunnelProviderManager?

    init(runtimeConfig: Data) { self.runtimeConfig = runtimeConfig }

    func loadAll() async throws {
        let all = try await NETunnelProviderManager.loadAllFromPreferences()
        let matching = all.filter { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.bundleId }
        let manager = matching.first ?? NETunnelProviderManager()
        for duplicate in matching.dropFirst() { try? await duplicate.removeFromPreferences() }

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.bundleId
        proto.serverAddress = "Android USB Relay"
        proto.providerConfiguration = ["runtimeConfig": runtimeConfig]
        manager.protocolConfiguration = proto
        manager.localizedDescription = "DroidBridge"
        manager.isEnabled = true
        self.manager = manager
    }

    func save() async throws { try await manager?.saveToPreferences() }
    func reload() async throws { try await manager?.loadFromPreferences() }
    func startTunnel() async throws { try manager?.connection.startVPNTunnel(options: nil) }
    func stopTunnel() async { manager?.connection.stopVPNTunnel() }

    func waitUntilDisconnected() async {
        guard let connection = manager?.connection else { return }
        for _ in 0..<50 where connection.status != .disconnected && connection.status != .invalid {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Sends a compact provider message and returns the (capped) response.
    func sendMessage(_ message: ProviderMessage) async -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else { return nil }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(message.encoded()) { response in
                    if let response, response.count <= ProviderResponse.maxSize { continuation.resume(returning: response) }
                    else { continuation.resume(returning: nil) }
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }
}
