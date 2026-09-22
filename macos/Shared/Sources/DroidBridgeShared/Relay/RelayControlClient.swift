import Foundation

/// Byte transport for the DBP control connection (loopback 127.0.0.1:27183).
public protocol DbpConnection: Sendable {
    func send(_ data: Data) async throws
    func receiveExactly(_ count: Int) async throws -> Data
    func close() async
}

/// Mac side of the DBP/1 control protocol: HELLO/HELLO_OK then HEALTH, with HMAC + bounds validation.
public struct RelayControlClient: Sendable {
    private let connectionFactory: @Sendable () async throws -> DbpConnection
    private let secret: Data
    private let now: @Sendable () -> UInt64

    public init(secret: Data,
                connectionFactory: @escaping @Sendable () async throws -> DbpConnection,
                now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.secret = secret
        self.connectionFactory = connectionFactory
        self.now = now
    }

    public func health(timeout: Duration = .seconds(3)) async throws -> RelayHealth {
        let box = DbpConnectionBox()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: RelayHealth.self) { group in
                group.addTask {
                    let connection = try await connectionFactory()
                    guard await box.store(connection) else {
                        throw CancellationError()
                    }
                    return try await performHealth(connection)
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    await box.close()
                    throw DroidBridgeError.relayTimedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw DroidBridgeError.relayTimedOut
                }
                return result
            }
        } onCancel: {
            Task { await box.close() }
        }
    }

    private func performHealth(_ connection: any DbpConnection) async throws -> RelayHealth {
        defer { Task { await connection.close() } }

        let clientNonce = UInt64.random(in: 1 ... .max)
        let timestamp = now()
        let hello = DbpHeader(type: .hello, clientNonce: clientNonce, serverNonce: 0, unixTime: timestamp)
        try await connection.send(DbpCodec.frame(secret: secret, header: hello))

        let (helloOk, _) = try await readMessage(connection)
        guard helloOk.type == .helloOk else { throw DroidBridgeError.relayProtocol("expected HELLO_OK") }
        guard helloOk.clientNonce == clientNonce, helloOk.serverNonce != 0 else { throw DroidBridgeError.relayAuthenticationFailed }
        let serverNonce = helloOk.serverNonce

        let healthRequest = DbpHeader(type: .health, clientNonce: clientNonce, serverNonce: serverNonce, unixTime: now())
        try await connection.send(DbpCodec.frame(secret: secret, header: healthRequest))

        let (responseHeader, payload) = try await readMessage(connection)
        guard responseHeader.type == .healthResponse else {
            if responseHeader.type == .openError { throw DroidBridgeError.relayAppNotRunning }
            throw DroidBridgeError.relayProtocol("expected HEALTH_RESPONSE")
        }
        guard responseHeader.serverNonce == serverNonce, responseHeader.clientNonce == clientNonce else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        let health = try DbpCodec.decodeHealth([UInt8](payload))
        if health.status == .cellularUnavailable { throw DroidBridgeError.cellularUnavailable }
        return health
    }

    /// Reads a full DBP message: 64-byte header, verifies HMAC, then the type's exact payload.
    private func readMessage(_ connection: DbpConnection) async throws -> (DbpHeader, Data) {
        let headerBytes = try await connection.receiveExactly(DbpCodec.headerSize)
        let (header, hmac) = try DbpCodec.decodeHeader(headerBytes)
        let prefixLen = DbpCodec.payloadPrefixLength(header.type)
        let prefix = prefixLen > 0 ? try await connection.receiveExactly(prefixLen) : Data()
        let remaining = try DbpCodec.payloadRemaining(header.type, prefix: [UInt8](prefix))
        let rest = remaining > 0 ? try await connection.receiveExactly(remaining) : Data()
        let payload = prefix + rest
        let expected = DbpCodec.computeHMAC(secret: secret, header: header, payload: payload)
        guard expected == hmac else { throw DroidBridgeError.relayAuthenticationFailed }
        return (header, payload)
    }
}

private actor DbpConnectionBox {
    private var connection: (any DbpConnection)?
    private var closed = false

    func store(_ connection: any DbpConnection) async -> Bool {
        guard !closed else {
            await connection.close()
            return false
        }
        self.connection = connection
        return true
    }

    func close() async {
        closed = true
        guard let connection else { return }
        self.connection = nil
        await connection.close()
    }
}
