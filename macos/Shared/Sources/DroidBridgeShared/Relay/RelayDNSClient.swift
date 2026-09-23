import Foundation

/// One authenticated, deadline-bound connection per DNS query. No query names are logged.
public struct RelayDNSClient: Sendable {
    private let secret: Data
    private let transportFactory: @Sendable () -> any RelayTransport
    private let now: @Sendable () -> UInt64
    public init(secret: Data, transportFactory: @escaping @Sendable () -> any RelayTransport,
                now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.secret = secret; self.transportFactory = transportFactory; self.now = now
    }
    public func query(_ dnsPacket: Data, timeout: Duration = .seconds(5)) async throws -> Data {
        guard (12...4096).contains(dnsPacket.count) else { throw DroidBridgeError.relayProtocol("dns size") }
        let transport = transportFactory()
        return try await relayDeadline(transport, timeout: timeout) {
            let session = RelaySession(transport: transport, secret: secret, clientNonce: .random(in: 1 ... .max), now: now)
            let nonce = try await session.hello()
            try await session.send(.dnsQuery, serverNonce: nonce, payload: wireInteger(UInt16(dnsPacket.count)) + dnsPacket)
            let (header, payload) = try await session.read(serverNonce: nonce)
            let dns = Data(payload.dropFirst(2))
            guard header.type == .dnsResponse, (12...4096).contains(dns.count), dns.prefix(2) == dnsPacket.prefix(2) else { throw DroidBridgeError.relayProtocol("dns response") }
            return dns
        }
    }
}
