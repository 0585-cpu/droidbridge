import Foundation

/// Bidirectional raw-IPv4 packet source used by both NetworkExtension and utun hosts.
public protocol PacketSource: AnyObject {
    /// Performs one read and invokes the handler once with a packet batch.
    func read(_ handler: @escaping @Sendable ([Data]) -> Void)
    func write(_ packets: [Data])
}

/// Minimal input surface exposed by the packet engine to transport-independent hosts.
public protocol PacketIngesting: AnyObject {
    func ingest(_ packet: Data)
}
