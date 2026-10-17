import Foundation
import CryptoKit

/// Transport integrity only; DBP authentication and application TLS remain inside this envelope.
public struct ReliableUsbRecord: Sendable {
    public enum Kind: UInt8, Sendable { case hello = 1, helloAck, data, ack }
    public static let maximumPayload = 16384
    static let magic = Data("DBR3LINK".utf8)
    public let kind: Kind
    public let epoch: Data
    public let sequence: UInt64
    public let ack: UInt64
    public let payload: Data

    public init(kind: Kind, epoch: Data, sequence: UInt64 = 0, ack: UInt64 = 0, payload: Data = Data()) throws {
        guard epoch.count == 16, sequence <= UInt64(Int64.max), ack <= UInt64(Int64.max),
              payload.count <= Self.maximumPayload,
              kind == .data ? sequence > 0 && !payload.isEmpty : sequence == 0 && payload.isEmpty,
              kind == .hello || kind == .helloAck ? ack == 0 : true else {
            throw AoaError.protocolViolation("invalid reliable USB record")
        }
        self.kind = kind; self.epoch = epoch; self.sequence = sequence; self.ack = ack; self.payload = payload
    }
    public func encoded() -> Data {
        var header = Self.magic + Data([kind.rawValue,0,0,0]) + AoaFrame.bytes(UInt32(payload.count))
        header.append(epoch); header.append(AoaFrame.consumedBytes(sequence)); header.append(AoaFrame.consumedBytes(ack))
        header.append(Data(SHA256.hash(data: payload).prefix(16)))
        // Validate the length before waiting for the body. A damaged in-range length
        // must not hide subsequent short records until the retry deadline.
        header.append(Data(SHA256.hash(data: header).prefix(16)))
        return header + payload
    }
}

/// Never forwards unverified bytes. After omission/corruption, scanning resumes at the next record.
public struct ReliableUsbDecoder: Sendable {
    private var pending = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [ReliableUsbRecord] {
        guard bytes.count <= 65536 else { throw AoaError.protocolViolation("USB read chunk too large") }
        pending.append(bytes)
        var result: [ReliableUsbRecord] = []
        while pending.count >= 8 {
            if !pending.starts(with: ReliableUsbRecord.magic) {
                if let range = pending.range(of: ReliableUsbRecord.magic, in: pending.index(after: pending.startIndex)..<pending.endIndex) {
                    pending = Data(pending[range.lowerBound...])
                } else { pending = Data(pending.suffix(7)); break }
            }
            guard pending.count >= 80 else { break }
            let header = Array(pending.prefix(80))
            guard Data(SHA256.hash(data: Data(header.prefix(64))).prefix(16)) == Data(header[64..<80]) else {
                pending.removeFirst(); continue
            }
            let length = Int(AoaFrame.number(Data(header[12..<16])))
            let sequence = AoaFrame.consumedCount(Data(header[32..<40]))
            let ack = AoaFrame.consumedCount(Data(header[40..<48]))
            guard let kind = ReliableUsbRecord.Kind(rawValue: header[8]),
                  header[9..<12].allSatisfy({ $0 == 0 }), length <= ReliableUsbRecord.maximumPayload,
                  sequence <= UInt64(Int64.max), ack <= UInt64(Int64.max),
                  kind == .data ? sequence > 0 && length > 0 : sequence == 0 && length == 0,
                  kind == .hello || kind == .helloAck ? ack == 0 : true else {
                pending.removeFirst(); continue
            }
            guard pending.count >= 80 + length else { break }
            let payload = Data(pending.dropFirst(80).prefix(length))
            let digest = Data(SHA256.hash(data: payload).prefix(16))
            guard digest == Data(header[48..<64]) else { pending.removeFirst(); continue }
            result.append(try ReliableUsbRecord(kind: kind, epoch: Data(header[16..<32]), sequence: sequence, ack: ack, payload: payload))
            pending.removeFirst(80 + length)
        }
        return result
    }
}
