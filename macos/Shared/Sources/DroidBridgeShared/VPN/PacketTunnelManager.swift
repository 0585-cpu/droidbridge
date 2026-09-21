import Foundation

/// Drives the VPN configuration lifecycle in the fixed order load -> save -> reload -> start. No secret
/// is ever placed in start options.
public struct PacketTunnelManager: PacketTunnelManaging {
    private let preferences: any TunnelPreferences

    public init(preferences: any TunnelPreferences) { self.preferences = preferences }

    public func connect() async throws {
        try await preferences.loadAll()   // load all, keep first match, drop duplicates (impl detail)
        try await preferences.save()
        try await preferences.reload()
        try await preferences.startTunnel()
    }

    public func disconnect() async {
        await preferences.stopTunnel()
        await preferences.waitUntilDisconnected()
    }
}

/// Host Disconnect teardown in the exact order that restores default routing before the loopback relay
/// disappears: stop the VPN, wait for it to go down, remove the ADB forwards, then delete runtime config.
/// The pairing Keychain secret is never touched here.
public struct DisconnectWorkflow: Sendable {
    private let vpn: any PacketTunnelManaging
    private let adb: any RelayAdb
    private let configStore: any RuntimeConfigurationStore

    public init(vpn: any PacketTunnelManaging, adb: any RelayAdb, configStore: any RuntimeConfigurationStore) {
        self.vpn = vpn
        self.adb = adb
        self.configStore = configStore
    }

    public func run(serial: String) async {
        await vpn.disconnect() // stopVPN + waitUntilDisconnected
        try? await adb.removeForward(serial: serial, hostPort: RelayPreparer.relayPort)
        try? await adb.removeForward(serial: serial, hostPort: RelayPreparer.pairingPort)
        try? configStore.delete()
    }
}
