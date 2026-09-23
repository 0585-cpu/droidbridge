import Foundation

/// Authentication is shared by every extension command. Responses belong to exactly this nonce pair.
struct RelaySession: Sendable {
    let transport: any RelayTransport
    let secret: Data
    let clientNonce: UInt64
    let now: @Sendable () -> UInt64
    func send(_ type: DbpMessageType, serverNonce: UInt64, payload: Data = Data()) async throws {
        try Task.checkCancellation()
        try await transport.send(DbpCodec.frame(secret: secret, header: DbpHeader(type: type, clientNonce: clientNonce, serverNonce: serverNonce, unixTime: now()), payload: payload))
    }
    func read(serverNonce: UInt64? = nil) async throws -> (DbpHeader, Data) {
        let (header, hmac) = try DbpCodec.decodeHeader(await transport.receiveExactly(64))
        let length = DbpCodec.payloadPrefixLength(header.type)
        let payload: Data
        do {
            let prefix = length == 0 ? Data() : try await transport.receiveExactly(length)
            let remaining = try DbpCodec.payloadRemaining(header.type, prefix: [UInt8](prefix))
            payload = remaining == 0 ? prefix : try await prefix + transport.receiveExactly(remaining)
        } catch DroidBridgeError.relayProtocol(let message) where message == "peer closed" {
            throw DroidBridgeError.relayProtocol("truncated control payload")
        }
        guard DbpCodec.verifyHMAC(secret: secret, header: header, payload: payload, hmac: hmac),
              header.clientNonce == clientNonce, header.serverNonce != 0,
              serverNonce == nil || header.serverNonce == serverNonce else { throw DroidBridgeError.relayAuthenticationFailed }
        return (header, payload)
    }
    func hello() async throws -> UInt64 {
        try await transport.start()
        try await send(.hello, serverNonce: 0)
        let (header, _) = try await read()
        guard header.type == .helloOk else { throw DroidBridgeError.relayAuthenticationFailed }
        return header.serverNonce
    }
}

/// Closing the underlying transport releases blocked I/O before the task group joins its children.
private final class RelayDeadlineState: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func expire() { lock.withLock { expired = true } }
    func check() throws {
        try Task.checkCancellation()
        if lock.withLock({ expired }) { throw DroidBridgeError.relayTimedOut }
    }
}

func relayDeadline<T: Sendable>(_ transport: any RelayTransport, timeout: Duration,
                                operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let deadline = RelayDeadlineState()
    return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                do { let result = try await operation(); try deadline.check(); await transport.cancel(); try deadline.check(); return result }
                catch { await transport.cancel(); throw error }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                deadline.expire()
                await transport.cancel()
                throw DroidBridgeError.relayTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } onCancel: { Task { await transport.cancel() } }
}

public struct RelayExtensionClient: Sendable {
    private let secret: Data
    private let factory: @Sendable () -> any RelayTransport
    public init(secret: Data, transportFactory: @escaping @Sendable () -> any RelayTransport) { self.secret = secret; factory = transportFactory }
    public func capabilities(timeout: Duration = .seconds(3)) async throws -> RelayCapabilities {
        let transport = factory()
        return try await relayDeadline(transport, timeout: timeout) {
            let session = RelaySession(transport: transport, secret: secret, clientNonce: .random(in: 1 ... .max), now: { UInt64(Date().timeIntervalSince1970) })
            let nonce = try await session.hello()
            try await session.send(.capabilities, serverNonce: nonce)
            let response: (DbpHeader, Data)
            do { response = try await session.read(serverNonce: nonce) }
            catch DroidBridgeError.relayProtocol(let message) where message == "peer closed" {
                // A B1 peer closes an unknown command after the authenticated HELLO.
                return .legacy
            }
            if response.0.type == .openError && response.1 == Data([DbpErrorCode.versionUnsupported.rawValue]) { return .legacy }
            guard response.0.type == .capabilitiesResponse else { throw DroidBridgeError.relayProtocol("capabilities response") }
            return try DbpCodec.decodeCapabilities(response.1)
        }
    }
    public func echo(request: UInt32, family: UInt8, destination: Data, ttl: UInt8, payload: Data, timeout: Duration = .seconds(5)) async throws -> Data {
        guard (family == 4 && destination.count == 4) || (family == 6 && destination.count == 16), payload.count <= 1200 else { throw DroidBridgeError.relayProtocol("echo request") }
        let transport = factory()
        return try await relayDeadline(transport, timeout: timeout) {
            let session = RelaySession(transport: transport, secret: secret, clientNonce: .random(in: 1 ... .max), now: { UInt64(Date().timeIntervalSince1970) })
            let nonce = try await session.hello()
            let address = destination + Data(count: 16 - destination.count)
            let body = Data([family, ttl]) + wireInteger(UInt16(payload.count)) + wireInteger(request) + address + payload
            try await session.send(.icmpEcho, serverNonce: nonce, payload: body)
            let (header, response) = try await session.read(serverNonce: nonce)
            let b = [UInt8](response)
            guard header.type == .icmpResponse, b.count >= 32, wireRead(b,0,4) == request, b[4] == family,
                  Data(b[16..<32]) == address, Data(b.dropFirst(32)) == payload else { throw DroidBridgeError.relayProtocol("echo response") }
            return Data(b.dropFirst(32))
        }
    }
}
