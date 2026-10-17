import Foundation
import Darwin

struct HelperRecoveryState: Codable, Equatable {
    /// Informational: which interface the tunnel owned. Recovery does not need
    /// it — withdrawing the network service is idempotent and keyed by a fixed id.
    let utun: String
    /// Nil while PF setup is in flight. Persisting the intent first closes the
    /// crash window between loading the anchor and receiving the PF token.
    let pfEnableToken: String?
    /// PF references belong to one kernel boot, unlike this on-disk journal.
    let bootSessionUUID: String?

    init(utun: String, pfEnableToken: String?, bootSessionUUID: String? = HelperRecoveryStateStore.currentBootUUID()) {
        self.utun = utun
        self.pfEnableToken = pfEnableToken
        self.bootSessionUUID = bootSessionUUID
    }
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

/// Root-owned crash recovery journal. It is deliberately persisted before PF
/// loads and the tunnel becomes the primary network, so a restarted helper can
/// withdraw the network service and release only the PF reference it acquired.
final class HelperRecoveryStateStore: @unchecked Sendable {
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
        let state = try JSONDecoder().decode(
            HelperRecoveryState.self,
            from: Data(contentsOf: url, options: [.mappedIfSafe])
        )
        let fromPreviousBoot: Bool
        if let savedBoot = state.bootSessionUUID, let currentBoot = Self.currentBootUUID() {
            fromPreviousBoot = savedBoot != currentBoot
        } else if state.bootSessionUUID == nil,
                  let modified = attributes[.modificationDate] as? Date,
                  let bootDate = Self.currentBootDate() {
            // Upgrade legacy records written before boot identity was persisted.
            fromPreviousBoot = modified < bootDate
        } else {
            fromPreviousBoot = false // Unknown identity must retain the recoverable reference.
        }
        if fromPreviousBoot {
            // Keep the journal until explicit Stop withdraws our service and clears our anchor.
            // Never release an old token in a new kernel, where it is absent or could be reused.
            return HelperRecoveryState(utun: state.utun, pfEnableToken: nil, bootSessionUUID: state.bootSessionUUID)
        }
        return state
    }

    static func currentBootUUID() -> String? {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func currentBootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }

    func save(_ state: HelperRecoveryState) throws {
        let data = try JSONEncoder().encode(state)
        // A system daemon must recover before a user unlocks the session. File-protection
        // classes can reject writes on macOS; use an atomic, owner-only POSIX journal.
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".recovery-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw posixError() }
        defer { Darwin.close(fd); try? fileManager.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw posixError() }
                offset += written
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw posixError() }
    }

    private func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    func remove() throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
