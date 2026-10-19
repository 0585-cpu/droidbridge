import Foundation

/// Caller serializes access with its session lock. UUID ownership fences late I/O callbacks.
public struct UDPAssociationIndex: Sendable {
    private struct Source: Hashable, Sendable { let family: UInt8; let port: UInt16; let address: Data }
    public struct Binding: Sendable {
        public let token: UUID
        public let peer: UDPAssociationPeer
    }
    public struct Attachment: Sendable { public let token: UUID; public let created: Bool }
    public struct Removal: Sendable { public let token: UUID; public let last: Bool }
    private var sources: [Source: UUID] = [:]
    private var groups: [UUID: (source: Source, peers: [UDPAssociationPeer: UInt32])] = [:]
    private var bindings: [UInt32: Binding] = [:]
    public init() {}
    public mutating func attach(flow: UInt32, sourcePort: UInt16, peer: UDPAssociationPeer, sourceAddress: Data) -> Attachment {
        let source = Source(family: peer.family, port: sourcePort, address: sourceAddress)
        let existing = sources[source]
        let token = existing ?? UUID()
        if existing == nil { sources[source] = token; groups[token] = (source, [:]) }
        groups[token]?.peers[peer] = flow
        bindings[flow] = Binding(token: token, peer: peer)
        return Attachment(token: token, created: existing == nil)
    }
    public func binding(flow: UInt32) -> Binding? { bindings[flow] }
    public func flow(token: UUID, peer: UDPAssociationPeer) -> UInt32? { groups[token]?.peers[peer] }
    public mutating func detach(flow: UInt32) -> Removal? {
        guard let binding = bindings.removeValue(forKey: flow), var group = groups[binding.token] else { return nil }
        group.peers.removeValue(forKey: binding.peer)
        let last = group.peers.isEmpty
        if last {
            groups.removeValue(forKey: binding.token)
            if sources[group.source] == binding.token { sources.removeValue(forKey: group.source) }
        } else { groups[binding.token] = group }
        return Removal(token: binding.token, last: last)
    }
    public mutating func remove(token: UUID) -> [UInt32] {
        guard let group = groups.removeValue(forKey: token) else { return [] }
        if sources[group.source] == token { sources.removeValue(forKey: group.source) }
        let flows = Array(group.peers.values)
        for flow in flows where bindings[flow]?.token == token { bindings.removeValue(forKey: flow) }
        return flows
    }
    public mutating func removeAll() -> [UInt32] {
        let flows = Array(bindings.keys)
        bindings.removeAll(); groups.removeAll(); sources.removeAll()
        return flows
    }
}

/// Synchronous registration preserves open -> send ordering from the C engine queue.
/// Removing a flow also discards its unsent packets; already-popped I/O is in flight.
public final class UDPAssociationQueue: @unchecked Sendable {
    public struct Packet: Sendable { public let flow: UInt32; public let peer: UDPAssociationPeer; public let payload: Data }
    private let lock = NSLock()
    private var peers: [UInt32: UDPAssociationPeer] = [:]
    private var packets: [Packet] = []
    private var bytes = 0
    private var dropped: UInt64 = 0
    private var closed = false
    private var limit = DatagramFrame.maximumPayload
    public init() {}
    /// Drops what the phone cannot take: it rejects an oversized datagram by closing the stream.
    public func restrict(to maximum: Int) {
        lock.withLock {
            limit = min(limit, maximum)
            packets.removeAll { if $0.payload.count > limit { bytes -= $0.payload.count; dropped &+= 1; return true }; return false }
        }
    }
    public func register(flow: UInt32, peer: UDPAssociationPeer) { lock.withLock { if !closed { peers[flow] = peer } } }
    public func remove(flow: UInt32) {
        lock.withLock {
            peers.removeValue(forKey: flow)
            packets.removeAll { if $0.flow == flow { bytes -= $0.payload.count; return true }; return false }
        }
    }
    @discardableResult public func append(flow: UInt32, payload: Data) -> Bool {
        lock.withLock {
            guard !closed, let peer = peers[flow] else { return false }
            guard payload.count <= limit else { dropped &+= 1; return false }
            let wake = packets.isEmpty
            while packets.count >= 64 || bytes + payload.count > 256 * 1024 {
                bytes -= packets.removeFirst().payload.count; dropped &+= 1
            }
            packets.append(Packet(flow: flow, peer: peer, payload: payload)); bytes += payload.count
            return wake
        }
    }
    public func pop() -> Packet? {
        lock.withLock {
            guard !packets.isEmpty else { return nil }
            let packet = packets.removeFirst(); bytes -= packet.payload.count
            return packet
        }
    }
    public var drops: UInt64 { lock.withLock { dropped } }
    public func close() { lock.withLock { closed = true; peers.removeAll(); packets.removeAll(); bytes = 0 } }
}
