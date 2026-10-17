import Foundation

/// A numeric endpoint. Family follows the byte count, avoiding textual IPv6 aliases.
public struct UDPAssociationPeer: Hashable, Sendable {
    public let address: Data
    public let port: UInt16
    public var family: UInt8 { address.count == 4 ? 4 : 6 }
    public init(address: Data, port: UInt16) throws {
        guard (address.count == 4 || address.count == 16), port != 0 else {
            throw DroidBridgeError.relayProtocol("association peer")
        }
        self.address = Data(address); self.port = port
    }
}

extension DbpCodec {
    public static func encodeOpenUDPAssociation(family: UInt8, idle: UInt16 = 120) throws -> Data {
        guard (family == 4 || family == 6), (30...300).contains(idle) else {
            throw DroidBridgeError.relayProtocol("association open")
        }
        return Data([family, 0]) + wireInteger(idle)
    }
}

public struct UDPAssociationFrame: Equatable, Sendable {
    public static let headerSize = 28
    public let peer: UDPAssociationPeer
    public let payload: Data
    public let inbound: Bool
    public let sequence: UInt32
    public init(peer: UDPAssociationPeer, payload: Data, inbound: Bool, sequence: UInt32) {
        self.peer = peer; self.payload = payload; self.inbound = inbound; self.sequence = sequence
    }
    public func encoded() throws -> Data {
        guard payload.count <= DatagramFrame.maximumPayload else { throw DroidBridgeError.relayProtocol("association size") }
        return wireInteger(UInt16(payload.count)) + Data([inbound ? 1 : 0, peer.family]) + wireInteger(sequence)
            + wireInteger(peer.port) + Data(count: 2) + peer.address + Data(count: 16 - peer.address.count) + payload
    }
    public static func payloadLength(header: Data) throws -> Int {
        let h = [UInt8](header)
        guard h.count == headerSize, h[2] <= 1, (h[3] == 4 || h[3] == 6),
              h[10] == 0, h[11] == 0, wireRead(h,8,2) != 0,
              h[3] != 4 || h[16..<28].allSatisfy({ $0 == 0 }) else {
            throw DroidBridgeError.relayProtocol("association header")
        }
        let length = Int(wireRead(h,0,2))
        guard length <= DatagramFrame.maximumPayload else { throw DroidBridgeError.relayProtocol("association size") }
        return length
    }
    public static func decode(_ data: Data) throws -> Self {
        let length = try payloadLength(header: Data(data.prefix(headerSize)))
        guard data.count == headerSize + length else { throw DroidBridgeError.relayProtocol("association length") }
        let h = [UInt8](data.prefix(headerSize))
        let peer = try UDPAssociationPeer(address: Data(h[12..<(h[3] == 4 ? 16 : 28)]), port: UInt16(wireRead(h,8,2)))
        return Self(peer: peer, payload: Data(data.dropFirst(headerSize)), inbound: h[2] == 1, sequence: UInt32(wireRead(h,4,4)))
    }
}
