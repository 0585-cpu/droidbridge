import Foundation

/// Events a flow raises back toward the packet engine. All bytes are copied; no buffers are shared.
public protocol RelayFlowDelegate: AnyObject, Sendable {
    func relayFlowOpened(_ flowId: UInt32)
    func relayFlowFailed(_ flowId: UInt32, error: DbpErrorCode)
    /// Returns only once this chunk is consumed; false ends a retired/failed flow.
    func relayFlowReceived(_ flowId: UInt32, data: Data) async -> Bool
    func relayFlowWritable(_ flowId: UInt32)
    /// Remote FIN: finish delivery to the client without closing its upload direction.
    func relayFlowReadEOF(_ flowId: UInt32)
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
    private var closed = false
    private var readFinished = false
    private var writeFinished = false
    private var receiveTask: Task<Void, Never>?
    private let now: @Sendable () -> UInt64

    /// Lock-protected bounded FIFO so the C engine's send callback can enqueue synchronously.
    final class OutboundBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int
        private var sealed = false
        init(limit: Int) { self.limit = limit }
        func append(_ chunk: Data) -> Bool {
            lock.withLock {
                guard !sealed, data.count + chunk.count <= limit else { return false }
                data.append(chunk); return true
            }
        }
        func takeAll() -> Data { lock.withLock { let d = data; data = Data(); return d } }
        var count: Int { lock.withLock { data.count } }
        var isEmpty: Bool { lock.withLock { data.isEmpty } }
        func finish() { lock.withLock { sealed = true } }
        var isFinished: Bool { lock.withLock { sealed && data.isEmpty } }
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
        guard !closed else { throw CancellationError() }
        try await transport.start()
        // HELLO -> HELLO_OK
        try await sendControl(.hello, payload: Data())
        let (helloOk, _) = try await readControl()
        guard helloOk.type == .helloOk, helloOk.clientNonce == clientNonce, helloOk.serverNonce != 0 else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        serverNonce = helloOk.serverNonce
        // OPEN_TCP -> OPEN_OK | OPEN_ERROR
        try await sendControl(.openTcp, payload: DbpCodec.encodeOpenTcp(destination: destination))
        let (open, openPayload) = try await readControl()
        guard !closed, open.clientNonce == clientNonce, open.serverNonce == serverNonce else { throw DroidBridgeError.relayAuthenticationFailed }
        switch open.type {
        case .openOk:
            opened = true
            delegate?.relayFlowOpened(flowId)
            pumpSend()
            receiveTask = Task { await self.receiveLoop() }
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

    public func close() async {
        guard !closed else { return }
        closed = true; opened = false
        receiveTask?.cancel(); receiveTask = nil
        outbound.finish()
        _ = outbound.takeAll()
        await transport.cancel()
    }

    /// Called synchronously after the engine has drained all request bytes into this FIFO.
    public nonisolated func finishSending() {
        outbound.finish()
        Task { await self.pumpSend() }
    }

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
        guard DbpCodec.verifyHMAC(secret: secret, header: header, payload: payload, hmac: hmac) else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        return (header, payload)
    }

    private func pumpSend() {
        guard opened, !closed, !sending else { return }
        let chunk = outbound.takeAll()
        if chunk.isEmpty {
            guard outbound.isFinished, !writeFinished else { return }
            sending = true
            Task {
                do {
                    try await transport.finishSending()
                    await self.finishSendCompleted()
                } catch { await self.failClosed() }
            }
            return
        }
        sending = true
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
        guard !closed else { return }
        sending = false
        delegate?.relayFlowWritable(flowId)
        pumpSend()
    }

    private func finishSendCompleted() async {
        guard !closed else { return }
        sending = false; writeFinished = true
        await finishIfComplete()
    }

    private func finishIfComplete() async {
        guard !closed, readFinished, writeFinished else { return }
        await close()
        delegate?.relayFlowClosed(flowId, isError: false)
    }

    private func failClosed() async {
        guard !closed else { return }; await close()
        delegate?.relayFlowClosed(flowId, isError: true)
    }

    private func receiveLoop() async {
        while !closed {
            let data: Data
            do { data = try await transport.receive(maxLength: Self.receiveChunk) }
            catch { await failClosed(); return }
            if data.isEmpty {
                guard !closed else { return }
                readFinished = true
                delegate?.relayFlowReadEOF(flowId)
                await finishIfComplete()
                return
            }
            guard !closed else { return }
            guard let delegate, await delegate.relayFlowReceived(flowId, data: data) else {
                await failClosed(); return
            }
        }
    }
}
