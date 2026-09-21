import DroidBridgeShared
import Foundation

/// In-memory DBP relay server for tests: authenticates HELLO, answers HEALTH. Runs its logic inside
/// send(), enqueueing the signed response so the client's next receiveExactly finds it.
final class EchoDbpServer: @unchecked Sendable {
    private let secret: Data
    private let health: RelayHealth
    init(secret: Data, health: RelayHealth) { self.secret = secret; self.health = health }

    func makeConnection() -> DbpConnection { EchoDbpConnection(secret: secret, health: health) }
}

private final class EchoDbpConnection: DbpConnection, @unchecked Sendable {
    private let secret: Data
    private let health: RelayHealth
    private let lock = NSLock()
    private var responses = Data()
    private var serverNonce: UInt64 = 0

    init(secret: Data, health: RelayHealth) { self.secret = secret; self.health = health }

    func send(_ data: Data) async throws {
        guard data.count >= 64, let (header, hmac) = try? DbpCodec.decodeHeader(data) else { return }
        // verify client HMAC (empty payload for HELLO/HEALTH)
        let expected = DbpCodec.computeHMAC(secret: secret, header: header, payload: Data())
        guard expected == hmac else { return } // silent: client will time out / fail
        switch header.type {
        case .hello:
            serverNonce = 0x1122334455667788
            let reply = DbpHeader(type: .helloOk, clientNonce: header.clientNonce, serverNonce: serverNonce, unixTime: header.unixTime)
            lock.withLock { responses.append(DbpCodec.frame(secret: secret, header: reply)) }
        case .health:
            let payload = encodeHealth(health)
            let reply = DbpHeader(type: .healthResponse, clientNonce: header.clientNonce, serverNonce: serverNonce, unixTime: header.unixTime)
            lock.withLock { responses.append(DbpCodec.frame(secret: secret, header: reply, payload: payload)) }
        default: break
        }
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        try lock.withLock {
            guard responses.count >= count else { throw DroidBridgeError.relayProtocol("peer closed") }
            let chunk = responses.prefix(count); responses.removeFirst(count); return Data(chunk)
        }
    }

    func close() async {}

    private func encodeHealth(_ h: RelayHealth) -> Data {
        var data = Data()
        data.append(h.status.rawValue)
        data.append(contentsOf: withUnsafeBytes(of: UInt16(h.activeSessions).bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(h.maximumSessions).bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: h.uploadedBytes.bigEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: h.downloadedBytes.bigEndian) { Array($0) })
        let name = Data(h.carrierName.utf8)
        data.append(UInt8(name.count))
        data.append(name)
        return data
    }
}
