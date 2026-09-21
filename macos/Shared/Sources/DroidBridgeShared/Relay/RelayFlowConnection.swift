import Foundation

/// Events a flow raises back toward the packet engine. All bytes are copied; no buffers are shared.
public protocol RelayFlowDelegate: AnyObject, Sendable {
    func relayFlowOpened(_ flowId: UInt32)
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode)
    func relayFlowReceived(_ flowId: UInt32, data: Data)
    func relayFlowWritable(_ flowId: UInt32)
    func relayFlowClosed(_ flowId: UInt32, isError: Bool)
}

/// One Android relay connection per TCP flow. Runs the DBP handshake (HELLO -> HELLO_OK -> OPEN_TCP ->
/// OPEN_OK), then bridges the raw byte stream. The outbound (Mac->relay) queue is bounded to 256 KiB and
/// applies backpressure instead of growing. The Pairing Secret is never logged.
public actor RelayFlowConnection {
    public static let outboundLimit = 256 * 1024
    public static let receiveChunk = 64 * 1024

    public let flowId: UInt32
    private let destination: OpenDestination
    private let secret: Data
    private let transport: any RelayTransport
    private weak var delegate: (any RelayFlowDelegate)?

    private let clientNonce: UInt64
    private var serverNonce: UInt64 = 0
    private let outbound: OutboundBuffer
    private var sending = false
    private var opened = false
    private let now: @Sendable () -> UInt64

    /// Lock-protected bounded FIFO so the C engine's send callback can enqueue synchronously.
    final class OutboundBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        init(limit: Int) { self.limit = limit }
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                guard data.count + chunk.count <= limit else { return false }
                data.append(chunk); return true
            }
        }
        func takeAll() -> Data { lock.withLock { let d = data; data = Data(); return d } }
        var count: Int { lock.withLock { data.count } }
        var isEmpty: Bool { lock.withLock { data.isEmpty } }
    }

    public init(flowId: UInt32, destination: OpenDestination, secret: Data,
                transport: any RelayTransport, delegate: any RelayFlowDelegate,
                clientNonce: UInt64 = UInt64.random(in: 1 ... .max),
                now: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970) }) {
        self.outbound = OutboundBuffer(limit: Self.outboundLimit)
        self.flowId = flowId
        self.destination = destination
        self.secret = secret
        self.transport = transport
        self.delegate = delegate
        self.clientNonce = clientNonce
        self.now = now
    }

    public nonisolated var bufferedOutboundBytes: Int { outbound.count }

    public func start() async throws {
        try await transport.start()
        // HELLO -> HELLO_OK
        try await sendControl(.hello, payload: Data())
        let (helloOk, _) = try await readControl()
        guard helloOk.type == .helloOk, helloOk.clientNonce == clientNonce, helloOk.serverNonce != 0 else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        serverNonce = helloOk.serverNonce
        // OPEN_TCP -> OPEN_OK | OPEN_ERROR
        try await sendControl(.openTcp, payload: DbpCodec.encodeOpenTcp(
            host: destination.host, port: destination.port))
        let (open, openPayload) = try await readControl()
        switch open.type {
        case .openOk:
            opened = true
            delegate?.relayFlowOpened(flowId)
            pumpSend()
            Task { await self.receiveLoop() }
        case .openError:
            let code = DbpErrorCode(rawValue: openPayload.first ?? 9) ?? .internalError
            delegate?.relayFlowFailed(flowId, error: code)
            await transport.cancel()
        default:
            throw DroidBridgeError.relayProtocol("unexpected \(open.type)")
        }
    }

    /// Called (synchronously) by the engine with Mac->relay bytes. Returns false when the queue is full.
    public nonisolated func enqueueFromCore(_ data: Data) -> Bool {
        let accepted = outbound.append(data)
        if accepted { Task { await self.pumpSend() } }
        return accepted
    }

    public func close() async { await transport.cancel() }

    // MARK: - internals

    private func sendControl(_ type: DbpMessageType, payload: Data) async throws {
        let header = DbpHeader(type: type, clientNonce: clientNonce, serverNonce: serverNonce, unixTime: now())
        try await transport.send(DbpCodec.frame(secret: secret, header: header, payload: payload))
    }

    private func readControl() async throws -> (DbpHeader, Data) {
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

    private func pumpSend() {
        guard opened, !sending, !outbound.isEmpty else { return }
        sending = true
        let chunk = outbound.takeAll()
        Task {
            do {
                try await transport.send(chunk)
                await self.sendCompleted()
            } catch {
                await self.failClosed()
            }
        }
    }

    private func sendCompleted() {
        sending = false
        delegate?.relayFlowWritable(flowId)
        if !outbound.isEmpty { pumpSend() }
    }

    private func failClosed() {
        delegate?.relayFlowClosed(flowId, isError: true)
    }

    private func receiveLoop() async {
        while true {
            let data: Data
            do { data = try await transport.receive(maxLength: Self.receiveChunk) }
            catch { delegate?.relayFlowClosed(flowId, isError: true); return }
            if data.isEmpty { delegate?.relayFlowClosed(flowId, isError: false); return } // clean EOF
            delegate?.relayFlowReceived(flowId, data: data)
        }
    }
}
