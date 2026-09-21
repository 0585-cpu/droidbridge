import Foundation
import Security

/// Shared-Keychain store reachable by the HostApp and the Packet Tunnel extension only.
/// Requires the `keychain-access-groups` entitlement, so it works only in the signed app.
public struct KeychainPairingSecretStore: PairingSecretStore {
    private let service = "io.droidbridge.pairing.v1"
    private let accessGroup: String

    public init(accessGroup: String) { self.accessGroup = accessGroup }

    private func baseQuery(peerId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: peerId,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    public func save(_ secret: Data, peerId: String) throws {
        try validate(secret)
        let query = baseQuery(peerId: peerId)
        let attributes: [String: Any] = [
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DroidBridgeError.keychainFailure(status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw DroidBridgeError.keychainFailure(status: updateStatus)
        }
    }

    public func load(peerId: String) throws -> Data? {
        var query = baseQuery(peerId: peerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw DroidBridgeError.keychainFailure(status: status)
        }
    }

    public func delete(peerId: String) throws {
        let status = SecItemDelete(baseQuery(peerId: peerId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DroidBridgeError.keychainFailure(status: status)
        }
    }
}
