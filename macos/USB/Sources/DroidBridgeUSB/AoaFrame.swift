import Foundation

public enum AoaError: Error, LocalizedError {
    case protocolViolation(String)
    case usb(String)
    public var errorDescription: String? {
        switch self {
        case .protocolViolation(let reason): "USB transport protocol error: \(reason)"
        case .usb(let reason): "USB connection: \(reason)"
        }
    }
}

public struct AoaFrame: Equatable, Sendable {
    public enum Kind: UInt8, Sendable { case open = 1, openOK, data, fin, close, window, reset, resetOK, ping, pong }
    public enum Service: UInt8, Sendable { case none = 0, relay, pairing }
    public static let maximumPayload = 16_384
    // Sender-only cap; the decoder continues accepting the existing wire maximum.
    public static let sendPayload = 16_384 - 16 - 80
    // Frames the writer may pack into one reliable record (one 16 KiB bulk write).
    public static let writeBudget = 16_384 - 80
    public static let initialCredit = 65_536
    public let type: Kind
    public let streamID: UInt32
    public let service: Service
    public let payload: Data

    public init(type: Kind, streamID: UInt32, service: Service = .none, payload: Data = Data()) throws {
        try Self.validate(type: type, streamID: streamID, service: service, length: payload.count)
        if type == .window {
            guard Self.consumedCount(payload) <= UInt64(Int64.max) else {
                throw AoaError.protocolViolation("invalid consumed count")
            }
        }
        self.type = type; self.streamID = streamID; self.service = service; self.payload = payload
    }

    static func validate(type: Kind, streamID: UInt32, service: Service, length: Int) throws {
        if type.rawValue >= Kind.reset.rawValue {
            guard streamID == 0, service == .none,
                  length == (type == .reset || type == .resetOK ? 16 : 0) else {
                throw AoaError.protocolViolation("session control")
            }
            return
        }
        guard streamID > 0, streamID <= Int32.max, streamID & 1 == 1,
              length <= maximumPayload else { throw AoaError.protocolViolation("stream or length") }
        guard type == .open ? service != .none : service == .none else {
            throw AoaError.protocolViolation("service")
        }
        switch type {
        case .data: guard length > 0 else { throw AoaError.protocolViolation("empty DATA") }
        case .window: guard length == 8 else { throw AoaError.protocolViolation("credit length") }
        default: guard length == 0 else { throw AoaError.protocolViolation("control payload") }
        }
    }

    public func encoded() -> Data {
        var result = Data([0x44,0x42,0x41,0x4d, 2,type.rawValue,service.rawValue,0])
        result.append(Self.bytes(streamID)); result.append(Self.bytes(UInt32(payload.count)))
        result.append(payload)
        return result
    }
    public static func bytes(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    public static func number(_ data: Data) -> UInt32 {
        data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    public static func consumedBytes(_ value: UInt64) -> Data {
        bytes(UInt32(truncatingIfNeeded: value >> 32)) + bytes(UInt32(truncatingIfNeeded: value))
    }
    public static func consumedCount(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

public struct AoaFrameDecoder: Sendable {
    // Consumed bytes are dropped once per append, not per frame: a record packed with hundreds
    // of small frames would otherwise move the remaining buffer once for every frame.
    private var buffer: [UInt8] = []
    private var offset = 0
    public init() {}
    public mutating func append(_ data: Data) throws -> [AoaFrame] {
        guard data.count <= 65_536 else { throw AoaError.protocolViolation("read chunk too large") }
        buffer.append(contentsOf: data)
        defer { buffer.removeFirst(offset); offset = 0 }
        var frames: [AoaFrame] = []
        while buffer.count - offset >= 16 {
            let header = Array(buffer[offset..<offset + 16])
            guard Array(header[0..<4]) == [0x44,0x42,0x41,0x4d], header[7] == 0,
                  let type = AoaFrame.Kind(rawValue: header[5]),
                  let service = AoaFrame.Service(rawValue: header[6]) else {
                throw AoaError.protocolViolation("header")
            }
            guard header[4] == 2 else {
                throw AoaError.protocolViolation("AOA version mismatch; update both DroidBridge apps")
            }
            let id = AoaFrame.number(Data(header[8..<12]))
            let length = Int(AoaFrame.number(Data(header[12..<16])))
            try AoaFrame.validate(type: type, streamID: id, service: service, length: length)
            guard buffer.count - offset >= 16 + length else { break }
            let payload = Data(buffer[offset + 16..<offset + 16 + length])
            frames.append(try AoaFrame(type: type, streamID: id, service: service, payload: payload))
            offset += 16 + length
        }
        return frames
    }
    public func finish() throws {
        guard buffer.count == offset else { throw AoaError.protocolViolation("truncated frame") }
    }
}
