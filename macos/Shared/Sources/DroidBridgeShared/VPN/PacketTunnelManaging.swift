import Foundation

/// The NETunnelProviderManager operations the host needs, abstracted so the connect/disconnect ordering
/// is testable without NetworkExtension. The NE-backed implementation lives in the app target.
public protocol TunnelPreferences: Sendable {
    func loadAll() async throws
    func save() async throws
    func reload() async throws
    func startTunnel() async throws
    func stopTunnel() async
    func waitUntilDisconnected() async
}

public protocol PacketTunnelManaging: Sendable {
    func connect() async throws
    func disconnect() async
}
