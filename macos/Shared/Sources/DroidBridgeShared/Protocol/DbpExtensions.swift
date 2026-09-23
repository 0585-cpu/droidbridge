import Foundation
import Darwin

public enum RelayCapability: UInt64, Sendable {
    case tcp4 = 1, udp4 = 2, tcp6 = 4, udp6 = 8, icmp4 = 16, icmp6 = 32
    case nat64 = 64, networkEvents = 128, udpRebind = 256, trafficProfiles = 512
}

public struct RelayCapabilities: Codable, Equatable, Sendable {
    public let flags: UInt64
    public let cellularGeneration: UInt64
    public let ipv4TTL: UInt8
    public let ipv6HopLimit: UInt8
    public let policyFlags: UInt8
    public let uploadBytesPerSecond: UInt32
    public let downloadBytesPerSecond: UInt32
    public let burstBytes: UInt32
    public let activeUDP: UInt16
    public let udpDrops: UInt64
    public let nat64PrefixLength: UInt8
    public let nat64Prefix: Data
    public func supports(_ feature: RelayCapability) -> Bool { flags & feature.rawValue != 0 }
    public static let legacy = RelayCapabilities(flags: 1, cellularGeneration: 0, ipv4TTL: 0, ipv6HopLimit: 0, policyFlags: 0, uploadBytesPerSecond: 0, downloadBytesPerSecond: 0, burstBytes: 0, activeUDP: 0, udpDrops: 0, nat64PrefixLength: 0, nat64Prefix: Data(count: 16))
}

extension DbpCodec {
    public static func encodeOpenTcp(destination: OpenDestination) throws -> Data {
        switch destination {
        case .domain(let host, let port): return try encodeOpenTcp(host: host, port: port)
        default: return try literalDestination(destination)
        }
    }
    public static func encodeOpenUDP(destination: OpenDestination, idle: UInt16 = 120) throws -> Data {
        guard (30...300).contains(idle) else { throw DroidBridgeError.relayProtocol("udp idle") }
        return try literalDestination(destination) + wireInteger(idle)
    }
    static func literalDestination(_ destination: OpenDestination) throws -> Data {
        let family: Int32, count: Int, type: UInt8
        switch destination {
        case .ipv4: family = AF_INET; count = 4; type = 1
        case .ipv6: family = AF_INET6; count = 16; type = 2
        case .domain: throw DroidBridgeError.relayProtocol("literal required")
        }
        var address = [UInt8](repeating: 0, count: count)
        guard destination.port != 0, inet_pton(family, destination.host, &address) == 1 else { throw DroidBridgeError.relayProtocol("literal address") }
        return Data([type]) + wireInteger(destination.port) + Data([UInt8(count)]) + Data(address)
    }
    public static func decodeCapabilities(_ payload: Data) throws -> RelayCapabilities {
        let p = [UInt8](payload)
        guard p.count == 61, p[0] == 0, p[1] == 59, p[2] == 1 else { throw DroidBridgeError.relayProtocol("capabilities version/length") }
        let b = Array(p.dropFirst(2))
        let flags = wireRead(b, 1, 8)
        let prefix = Data(b[43..<59]), length = b[42]
        guard b[19] & ~3 == 0, wireRead(b,32,2) <= 256,
              [0,32,40,48,56,64,96].contains(Int(length)),
              (length == 0 ? prefix.allSatisfy { $0 == 0 } : flags & 64 != 0) else { throw DroidBridgeError.relayProtocol("capabilities bounds") }
        return RelayCapabilities(flags: flags, cellularGeneration: wireRead(b,9,8), ipv4TTL: b[17], ipv6HopLimit: b[18], policyFlags: b[19], uploadBytesPerSecond: UInt32(wireRead(b,20,4)), downloadBytesPerSecond: UInt32(wireRead(b,24,4)), burstBytes: UInt32(wireRead(b,28,4)), activeUDP: UInt16(wireRead(b,32,2)), udpDrops: wireRead(b,34,8), nat64PrefixLength: length, nat64Prefix: prefix)
    }
}

func wireInteger<T: FixedWidthInteger>(_ value: T) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
func wireRead(_ b: [UInt8], _ offset: Int, _ length: Int) -> UInt64 { b[offset..<(offset+length)].reduce(0) { ($0 << 8) | UInt64($1) } }

public struct DatagramFrame: Sendable, Equatable {
    public static let maximumPayload = 1232
    public let payload: Data
    public let inbound: Bool
    public let sequence: UInt32
    public init(payload: Data, inbound: Bool, sequence: UInt32) { self.payload = payload; self.inbound = inbound; self.sequence = sequence }
    public func encoded() throws -> Data {
        guard payload.count <= Self.maximumPayload else { throw DroidBridgeError.relayProtocol("datagram size") }
        return wireInteger(UInt16(payload.count)) + Data([inbound ? 1 : 0, 0]) + wireInteger(sequence) + payload
    }
    public static func payloadLength(header: Data) throws -> Int {
        let h = [UInt8](header)
        guard h.count == 8, h[2] <= 1, h[3] == 0 else { throw DroidBridgeError.relayProtocol("datagram header") }
        let length = Int(wireRead(h,0,2))
        guard length <= maximumPayload else { throw DroidBridgeError.relayProtocol("datagram size") }
        return length
    }
    public static func decode(_ data: Data) throws -> Self {
        let length = try payloadLength(header: Data(data.prefix(8)))
        guard data.count == length + 8 else { throw DroidBridgeError.relayProtocol("datagram length") }
        let h = [UInt8](data.prefix(8))
        return Self(payload: Data(data.dropFirst(8)), inbound: h[2] == 1, sequence: UInt32(wireRead(h,4,4)))
    }
}

/// Bounded packet FIFO; empty payload is a datagram, nil means no queued packet.
public final class DatagramQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var bytes = 0
    private var dropped: UInt64 = 0
    private var closed = false
    public init() {}
    @discardableResult public func append(_ data: Data) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            guard data.count <= DatagramFrame.maximumPayload else { dropped &+= 1; return false }
            let needsWake = packets.isEmpty
            while packets.count >= 64 || bytes + data.count > 256 * 1024 {
                bytes -= packets.removeFirst().count; dropped &+= 1
            }
            packets.append(data); bytes += data.count
            return needsWake
        }
    }
    public func pop() -> Data? { lock.withLock { guard !packets.isEmpty else { return nil }; let d = packets.removeFirst(); bytes -= d.count; return d } }
    public var count: Int { lock.withLock { packets.count } }
    public var drops: UInt64 { lock.withLock { dropped } }
    public func close() { lock.withLock { closed = true; packets.removeAll(); bytes = 0 } }
}
