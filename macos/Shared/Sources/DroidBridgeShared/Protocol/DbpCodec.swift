import Foundation
import CryptoKit

public enum DbpMessageType: UInt8, Sendable {
    case hello = 0x01, helloOk = 0x02
    case openTcp = 0x10, openOk = 0x11, openError = 0x12
    case dnsQuery = 0x20, dnsResponse = 0x21
    case health = 0x30, healthResponse = 0x31
}

public enum DbpErrorCode: UInt8, Sendable {
    case authFailed = 1, versionUnsupported = 2, policyDenied = 3, cellularUnavailable = 4
    case dnsFailed = 5, connectTimeout = 6, connectRefused = 7, sessionLimit = 8, internalError = 9
}

public enum DbpHealthStatus: UInt8, Sendable { case notReady = 0, ready = 1, cellularUnavailable = 2 }

public struct DbpHeader: Equatable, Sendable {
    public var type: DbpMessageType
    public var clientNonce: UInt64
    public var serverNonce: UInt64
    public var unixTime: UInt64
    public init(type: DbpMessageType, clientNonce: UInt64, serverNonce: UInt64, unixTime: UInt64) {
        self.type = type; self.clientNonce = clientNonce; self.serverNonce = serverNonce; self.unixTime = unixTime
    }
}

/// DBP/1 wire codec (spec §8). Matches protocol/test-vectors/dbp-v1.json byte-for-byte.
public enum DbpCodec {
    public static let headerSize = 64
    public static let hmacSize = 32
    private static let magic = Data("DBP1".utf8)

    public static func encodeHeader(_ header: DbpHeader, hmac: Data) -> Data {
        var data = Data(capacity: headerSize)
        data.append(magic)
        data.append(header.type.rawValue)
        data.append(0) // flags
        data.append(contentsOf: withUnsafeBytes(of: UInt16(headerSize).bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: header.clientNonce.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: header.serverNonce.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: header.unixTime.bigEndian) { Array($0) })
        data.append(hmac.count == hmacSize ? hmac : Data(count: hmacSize))
        return data
    }

    public static func decodeHeader(_ bytes: Data) throws -> (DbpHeader, hmac: Data) {
        let b = Data(bytes) // ensure zero-based indexing
        guard b.count >= headerSize else { throw DroidBridgeError.relayProtocol("truncated header") }
        guard b.prefix(4) == magic else { throw DroidBridgeError.relayProtocol("bad magic") }
        guard b[4 + b.startIndex] != nil else { throw DroidBridgeError.relayProtocol("type") }
        let arr = [UInt8](b.prefix(headerSize))
        guard let type = DbpMessageType(rawValue: arr[4]) else { throw DroidBridgeError.relayProtocol("message type") }
        guard arr[5] == 0 else { throw DroidBridgeError.relayProtocol("flags") }
        let headerLen = (UInt16(arr[6]) << 8) | UInt16(arr[7])
        guard headerLen == UInt16(headerSize) else { throw DroidBridgeError.relayProtocol("header length") }
        let header = DbpHeader(type: type,
                               clientNonce: readU64(arr, 8),
                               serverNonce: readU64(arr, 16),
                               unixTime: readU64(arr, 24))
        return (header, Data(arr[32..<64]))
    }

    public static func computeHMAC(secret: Data, header: DbpHeader, payload: Data) -> Data {
        let zeroed = encodeHeader(header, hmac: Data(count: hmacSize))
        let mac = HMAC<SHA256>.authenticationCode(for: zeroed + payload, using: SymmetricKey(data: secret))
        return Data(mac)
    }

    public static func frame(secret: Data, header: DbpHeader, payload: Data = Data()) -> Data {
        encodeHeader(header, hmac: computeHMAC(secret: secret, header: header, payload: payload)) + payload
    }

    /// Payload prefix length before the total payload size is known (mirrors Kotlin DbpCodec).
    public static func payloadPrefixLength(_ type: DbpMessageType) -> Int {
        switch type {
        case .hello, .helloOk, .openOk, .health: return 0
        case .openError: return 1
        case .openTcp: return 4
        case .dnsQuery, .dnsResponse: return 2
        case .healthResponse: return 22
        }
    }

    public static func payloadRemaining(_ type: DbpMessageType, prefix: [UInt8]) throws -> Int {
        switch type {
        case .healthResponse:
            guard prefix.count == 22 else { throw DroidBridgeError.relayProtocol("health prefix") }
            let nameLen = Int(prefix[21])
            guard nameLen <= 63 else { throw DroidBridgeError.relayProtocol("carrier length") }
            return nameLen
        case .dnsQuery, .dnsResponse:
            let len = (Int(prefix[0]) << 8) | Int(prefix[1])
            guard (12...4096).contains(len) else { throw DroidBridgeError.relayProtocol("dns length") }
            return len
        default: return 0
        }
    }

    public static func encodeOpenTcp(host: String, port: UInt16) throws -> Data {
        let name = Data(host.utf8)
        guard (1...253).contains(name.count), port != 0 else { throw DroidBridgeError.relayProtocol("open tcp") }
        var data = Data()
        data.append(3) // domain
        data.append(contentsOf: withUnsafeBytes(of: port.bigEndian) { Array($0) })
        data.append(UInt8(name.count))
        data.append(name)
        return data
    }

    public static func decodeHealth(_ payload: [UInt8]) throws -> RelayHealth {
        guard payload.count >= 22 else { throw DroidBridgeError.relayProtocol("health size") }
        guard let status = DbpHealthStatus(rawValue: payload[0]) else { throw DroidBridgeError.relayProtocol("health status") }
        let active = (UInt16(payload[1]) << 8) | UInt16(payload[2])
        let maximum = (UInt16(payload[3]) << 8) | UInt16(payload[4])
        let uploaded = readU64(payload, 5)
        let downloaded = readU64(payload, 13)
        let nameLen = Int(payload[21])
        guard maximum <= 256, active <= maximum, nameLen <= 63, payload.count == 22 + nameLen else {
            throw DroidBridgeError.relayProtocol("health bounds")
        }
        guard let carrier = String(bytes: payload[22..<(22 + nameLen)], encoding: .utf8) else {
            throw DroidBridgeError.relayProtocol("carrier utf8")
        }
        return RelayHealth(status: status, activeSessions: Int(active), maximumSessions: Int(maximum),
                           uploadedBytes: uploaded, downloadedBytes: downloaded, carrierName: carrier)
    }

    private static func readU64(_ a: [UInt8], _ offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(a[offset + i]) }
        return v
    }
}
