import Foundation

struct HelperRecoveryState: Codable, Equatable {
    let gateway: String
    let utun: String
    /// Nil while PF setup is in flight. Persisting the intent first closes the
    /// crash window between loading the anchor and receiving the PF token.
    let pfEnableToken: String?
    /// Each service's DNS before the tunnel pointed it at 198.18.0.1; `[]`
    /// means DHCP-provided. Optional (and defaulted) so journals written by a
    /// helper that predates DNS handling still decode after an upgrade.
    var dnsServers: [String: [String]]? = nil
}

enum HelperRecoveryStateStoreError: LocalizedError {
    case unsafeFile(URL)

    var errorDescription: String? {
        switch self {
        case let .unsafeFile(url):
            return "unsafe helper recovery state file at \(url.path)"
        }
    }
}

/// Root-owned crash recovery journal. It is deliberately persisted before the
/// default route moves so a restarted helper can restore connectivity and then
/// release only the PF reference that it acquired.
final class HelperRecoveryStateStore {
    static let defaultURL = URL(
        fileURLWithPath: "/Library/PrivilegedHelperTools/io.droidbridge.recovery.json"
    )

    private let url: URL
    private let fileManager: FileManager

    init(url: URL = defaultURL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    var hasPersistedState: Bool {
        fileManager.fileExists(atPath: url.path)
    }

    func load() throws -> HelperRecoveryState? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let type = attributes[.type] as? FileAttributeType, type != .typeRegular {
            throw HelperRecoveryStateStoreError.unsafeFile(url)
        }
        return try JSONDecoder().decode(
            HelperRecoveryState.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe])
        )
    }

    func save(_ state: HelperRecoveryState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
