import Foundation

/// Stores exactly one 32-byte Pairing Secret per peer id. Never exposes it as a String.
public protocol PairingSecretStore: Sendable {
    func save(_ secret: Data, peerId: String) throws
    func load(peerId: String) throws -> Data?
    func delete(peerId: String) throws
}

public extension PairingSecretStore {
    func validate(_ secret: Data) throws {
        guard secret.count == 32 else { throw DroidBridgeError.secretWrongLength }
    }
}

/// In-memory store for tests and previews.
public final class InMemoryPairingSecretStore: PairingSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    public private(set) var saveCount = 0
    public private(set) var deleteCount = 0
    public init() {}

    public func save(_ secret: Data, peerId: String) throws {
        try validate(secret)
        lock.withLock { items[peerId] = secret; saveCount += 1 }
    }
    public func load(peerId: String) throws -> Data? { lock.withLock { items[peerId] } }
    public func delete(peerId: String) throws { lock.withLock { if items.removeValue(forKey: peerId) != nil { deleteCount += 1 } } }
}
