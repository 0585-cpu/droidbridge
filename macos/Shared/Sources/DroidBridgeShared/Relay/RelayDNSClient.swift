import Foundation

/// Opens a short-lived DBP connection per DNS query, enforces a 5-second deadline, and validates the
/// response transaction id. Query names are never logged.
public struct RelayDNSClient: Sendable {
    private let secret: Data
    private let transportFactory: @Sendable () -> any RelayTransport
    private let now: @Sendable () -> UInt64

    public init(secret: Data, transportFactory: @escaping @Sendable () -> any RelayTransport,
                now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.secret = secret
        self.transportFactory = transportFactory
        self.now = now
    }

    public func query(_ dnsPacket: Data, timeout: Duration = .seconds(5)) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await self.performQuery(dnsPacket) }
            group.addTask { try await Task.sleep(for: timeout); throw DroidBridgeError.relayTimedOut }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw DroidBridgeError.relayTimedOut }
            return result
        }
    }

    private func performQuery(_ dnsPacket: Data) async throws -> Data {
        guard dnsPacket.count >= 12, dnsPacket.count <= 4096 else { throw DroidBridgeError.relayProtocol("dns size") }
        let txid = (UInt16(dnsPacket[dnsPacket.startIndex]) << 8) | UInt16(dnsPacket[dnsPacket.startIndex + 1])
        let transport = transportFactory()
        try await transport.start()
        defer { Task { await transport.cancel() } }

        let clientNonce = UInt64.random(in: 1 ... .max)
        let timestamp = now()
        try await transport.send(DbpCodec.frame(secret: secret,
            header: DbpHeader(type: .hello, clientNonce: clientNonce, serverNonce: 0, unixTime: timestamp)))
        let (helloOk, _) = try await readControl(transport)
        guard helloOk.type == .helloOk, helloOk.clientNonce == clientNonce, helloOk.serverNonce != 0 else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        let serverNonce = helloOk.serverNonce

        var payload = Data()
        payload.append(UInt8(dnsPacket.count >> 8)); payload.append(UInt8(dnsPacket.count & 0xFF))
        payload.append(dnsPacket)
        try await transport.send(DbpCodec.frame(secret: secret,
            header: DbpHeader(type: .dnsQuery, clientNonce: clientNonce, serverNonce: serverNonce, unixTime: now()),
            payload: payload))

        let (response, responsePayload) = try await readControl(transport)
        guard response.type == .dnsResponse else { throw DroidBridgeError.relayProtocol("expected DNS_RESPONSE") }
        let dns = responsePayload.suffix(from: responsePayload.startIndex + 2)
        guard dns.count >= 12, dns.count <= 4096 else { throw DroidBridgeError.relayProtocol("dns response size") }
        let responseTxid = (UInt16(dns[dns.startIndex]) << 8) | UInt16(dns[dns.startIndex + 1])
        guard responseTxid == txid else { throw DroidBridgeError.relayProtocol("dns txid mismatch") }
        return Data(dns)
    }

    private func readControl(_ transport: any RelayTransport) async throws -> (DbpHeader, Data) {
        let headerBytes = try await transport.receiveExactly(DbpCodec.headerSize)
        let (header, hmac) = try DbpCodec.decodeHeader(headerBytes)
        let prefixLen = DbpCodec.payloadPrefixLength(header.type)
        let prefix = prefixLen > 0 ? try await transport.receiveExactly(prefixLen) : Data()
        let remaining = try DbpCodec.payloadRemaining(header.type, prefix: [UInt8](prefix))
        let rest = remaining > 0 ? try await transport.receiveExactly(remaining) : Data()
        let payload = prefix + rest
        guard DbpCodec.computeHMAC(secret: secret, header: header, payload: payload) == hmac else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        return (header, payload)
    }
}
