import Foundation

/// Non-secret runtime configuration shared with the Packet Tunnel through the App Group.
/// The Pairing Secret itself is never stored here — only the Keychain account that references it.
public struct TunnelRuntimeConfiguration: Codable, Equatable, Sendable {
    public let deviceSerial: String
    public let relayHost: String
    public let relayPort: UInt16
    public let pairedPeerId: String
    public let keychainAccount: String
    public let maximumFlows: UInt16

    public static let loopback = "127.0.0.1"
    public static let relayPortB1: UInt16 = 27183

    public init(
        deviceSerial: String,
        relayHost: String,
        relayPort: UInt16,
        pairedPeerId: String,
        keychainAccount: String,
        maximumFlows: UInt16
    ) throws {
        guard relayHost == Self.loopback else {
            throw DroidBridgeError.invalidConfiguration("relay host must be loopback")
        }
        guard relayPort == Self.relayPortB1 else {
            throw DroidBridgeError.invalidConfiguration("relay port must be \(Self.relayPortB1)")
        }
        guard (1...256).contains(maximumFlows) else {
            throw DroidBridgeError.invalidConfiguration("maximumFlows must be 1...256")
        }
        self.deviceSerial = deviceSerial
        self.relayHost = relayHost
        self.relayPort = relayPort
        self.pairedPeerId = pairedPeerId
        self.keychainAccount = keychainAccount
        self.maximumFlows = maximumFlows
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            deviceSerial: container.decode(String.self, forKey: .deviceSerial),
            relayHost: container.decode(String.self, forKey: .relayHost),
            relayPort: container.decode(UInt16.self, forKey: .relayPort),
            pairedPeerId: container.decode(String.self, forKey: .pairedPeerId),
            keychainAccount: container.decode(String.self, forKey: .keychainAccount),
            maximumFlows: container.decode(UInt16.self, forKey: .maximumFlows)
        )
    }
}

extension JSONEncoder {
    /// Deterministic, secret-free encoding for App Group files.
    public static var droidBridge: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
