import Foundation

/// Pure source of truth for the B1 full-tunnel settings. `TunnelSettings.make(from:)` in the extension
/// is the only place this maps to NEPacketTunnelNetworkSettings.
public struct TunnelSettingsDescriptor: Equatable, Sendable {
    public let address: String
    public let subnetMask: String
    public let gateway: String
    public let dnsServers: [String]
    public let includedRoutes: [String]
    public let excludedRoutes: [String]
    public let mtu: Int

    public static let b1 = TunnelSettingsDescriptor(
        address: "198.18.0.2",
        subnetMask: "255.255.255.252",
        gateway: "198.18.0.1",
        dnsServers: ["198.18.0.1"],
        includedRoutes: ["0.0.0.0/0"],   // full tunnel
        excludedRoutes: ["127.0.0.0/8"], // loopback only
        mtu: 1500
    )
}
