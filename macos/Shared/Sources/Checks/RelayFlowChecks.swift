import DroidBridgeShared
import Foundation

private let flowSecret = Data([UInt8](repeating: 0, count: 31) + [1])

/// Scripted transport: server responses are pre-seeded; sent frames are recorded and classified.
final class ScriptedTransport: RelayTransport, @unchecked Sendable {
    enum Kind { case hello, openTCP, dnsQuery, other }
    private let lock = NSLock()
    private var inbox: Data
    private(set) var sentKinds: [Kind] = []
    private(set) var sentRaw: [Data] = []
    var started = false
    var cancelled = false
    private var finishCount = 0
    var finishes: Int { lock.withLock { finishCount } }

    init(responses: [Data]) { inbox = responses.reduce(Data(), +) }

    func start() async throws { started = true }
    func finishSending() async throws { lock.withLock { finishCount += 1 } }
    func cancel() async { cancelled = true }

    func send(_ data: Data) async throws {
        lock.withLock {
            sentRaw.append(data)
            // classify by DBP message type at offset 4 when it looks like a control frame
            if data.count >= 64, let (h, _) = try? DbpCodec.decodeHeader(data) {
                switch h.type {
                case .hello: sentKinds.append(.hello)
                case .openTcp: sentKinds.append(.openTCP)
                case .dnsQuery: sentKinds.append(.dnsQuery)
                default: sentKinds.append(.other)
                }
            } else {
                sentKinds.append(.other) // raw stream bytes
            }
        }
    }

    func receiveExactly(_ count: Int) async throws -> Data {
        try lock.withLock {
            guard inbox.count >= count else { throw DroidBridgeError.relayProtocol("eof") }
            let chunk = inbox.prefix(count); inbox.removeFirst(count); return Data(chunk)
        }
    }

    func receive(maxLength: Int) async throws -> Data {
        lock.withLock {
            if inbox.isEmpty { return Data() }
            let n = min(maxLength, inbox.count)
            let chunk = inbox.prefix(n); inbox.removeFirst(n); return Data(chunk)
        }
    }
}

final class RecordingFlowDelegate: RelayFlowDelegate, @unchecked Sendable {
    enum Event: Equatable { case opened(UInt32), failed(UInt32, DbpErrorCode), received(UInt32, Data), writable(UInt32), readEOF(UInt32), closed(UInt32, Bool) }
    private let lock = NSLock()
    private(set) var events: [Event] = []
    func relayFlowOpened(_ f: UInt32) { lock.withLock { events.append(.opened(f)) } }
    func relayFlowFailed(_ f: UInt32, error: DbpErrorCode) { lock.withLock { events.append(.failed(f, error)) } }
    func relayFlowReceived(_ f: UInt32, data: Data) async -> Bool { lock.withLock { events.append(.received(f, data)) }; return true }
    func relayFlowWritable(_ f: UInt32) { lock.withLock { events.append(.writable(f)) } }
    func relayFlowReadEOF(_ f: UInt32) { lock.withLock { events.append(.readEOF(f)) } }
    func relayFlowClosed(_ f: UInt32, isError: Bool) { lock.withLock { events.append(.closed(f, isError)) } }
    var snapshot: [Event] { lock.withLock { events } }
}

/// Signs a server->client control frame with the shared secret (mirrors the Android relay).
private func serverFrame(_ type: DbpMessageType, clientNonce: UInt64, serverNonce: UInt64, payload: Data = Data()) -> Data {
    let header = DbpHeader(type: type, clientNonce: clientNonce, serverNonce: serverNonce, unixTime: 1_700_000_000)
    return DbpCodec.frame(secret: flowSecret, header: header, payload: payload)
}

private func dnsQueryPacket(txid: UInt16) -> Data {
    var d = Data([UInt8(txid >> 8), UInt8(txid & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
    d.append(contentsOf: [7]); d.append("example".data(using: .ascii)!)
    d.append(contentsOf: [3]); d.append("com".data(using: .ascii)!)
    d.append(contentsOf: [0, 0, 1, 0, 1])
    return d
}

func runRelayFlowChecks(_ r: CheckRunner) {
    let cn: UInt64 = 0x51
    let sn: UInt64 = 0x1122334455667788

    // happy path: HELLO -> HELLO_OK, OPEN_TCP -> OPEN_OK, then a raw byte from the remote
    runBlocking {
        let transport = ScriptedTransport(responses: [
            serverFrame(.helloOk, clientNonce: cn, serverNonce: sn),
            serverFrame(.openOk, clientNonce: cn, serverNonce: sn),
            Data("pong".utf8),
        ])
        let delegate = RecordingFlowDelegate()
        let flow = RelayFlowConnection(flowId: 7, destination: .ipv4("93.184.216.34", 443),
                                       secret: flowSecret, transport: transport, delegate: delegate,
                                       clientNonce: cn, now: { 1_700_000_000 })
        try? await flow.start()
        try? await Task.sleep(for: .milliseconds(50)) // let the receive loop deliver
        r.check(transport.sentKinds.prefix(2).elementsEqual([.hello, .openTCP]), "sends HELLO then OPEN_TCP")
        let events = delegate.snapshot
        r.check(events.first == .opened(7), "opens flow only after authenticated OPEN_OK")
        r.check(events.contains(.received(7, Data("pong".utf8))), "delivers raw remote bytes")
    }

    // Remote FIN may precede the final upload. Seal only after all queued bytes are sent.
    runBlocking {
        let transport = ScriptedTransport(responses: [
            serverFrame(.helloOk, clientNonce: cn, serverNonce: sn),
            serverFrame(.openOk, clientNonce: cn, serverNonce: sn),
        ])
        let delegate = RecordingFlowDelegate()
        let flow = RelayFlowConnection(flowId: 71, destination: .ipv4("93.184.216.34", 443),
                                       secret: flowSecret, transport: transport, delegate: delegate,
                                       clientNonce: cn, now: { 1_700_000_000 })
        try? await flow.start()
        for _ in 0..<100 {
            if delegate.snapshot.contains(.readEOF(71)) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        r.check(delegate.snapshot.contains(.readEOF(71)), "remote FIN notifies only read EOF")
        r.check(!transport.cancelled, "remote FIN preserves upload transport")
        let tail = Data("upload-after-remote-FIN".utf8)
        r.check(flow.enqueueFromCore(tail), "upload accepted after remote FIN")
        flow.finishSending(); flow.finishSending()
        r.check(!flow.enqueueFromCore(Data([1])), "no bytes accepted after client FIN")
        for _ in 0..<100 {
            if delegate.snapshot.contains(.closed(71, false)) { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        r.check(transport.sentRaw.last == tail, "final upload delivered before completion")
        r.check(transport.finishes == 1, "duplicate client FIN sends one transport FIN")
        r.check(delegate.snapshot.filter { $0 == .closed(71, false) }.count == 1,
                "both EOFs release relay exactly once")
        r.check(transport.cancelled, "completed relay transport released")
    }

    // OPEN_ERROR maps to failed(errorCode)
    runBlocking {
        let transport = ScriptedTransport(responses: [
            serverFrame(.helloOk, clientNonce: cn, serverNonce: sn),
            serverFrame(.openError, clientNonce: cn, serverNonce: sn, payload: Data([DbpErrorCode.policyDenied.rawValue])),
        ])
        let delegate = RecordingFlowDelegate()
        let flow = RelayFlowConnection(flowId: 8, destination: .domain("x.test", 443),
                                       secret: flowSecret, transport: transport, delegate: delegate, clientNonce: cn, now: { 1_700_000_000 })
        try? await flow.start()
        r.check(delegate.snapshot == [.failed(8, .policyDenied)], "OPEN_ERROR maps to failed(code)")
    }

    // wrong HELLO_OK HMAC (wrong secret) -> auth failure, no open
    runBlocking {
        let bad = DbpHeader(type: .helloOk, clientNonce: cn, serverNonce: sn, unixTime: 1_700_000_000)
        let badFrame = DbpCodec.frame(secret: Data(count: 32), header: bad)
        let transport = ScriptedTransport(responses: [badFrame])
        let delegate = RecordingFlowDelegate()
        let flow = RelayFlowConnection(flowId: 9, destination: .ipv4("1.1.1.1", 443),
                                       secret: flowSecret, transport: transport, delegate: delegate, clientNonce: cn, now: { 1_700_000_000 })
        var threw = false
        do { try await flow.start() } catch { threw = true }
        r.check(threw, "wrong HELLO_OK HMAC throws")
        r.check(delegate.snapshot.isEmpty, "no open on auth failure")
    }

    // bounded outbound queue: 256 KiB accepted, one more byte refused, no growth
    runBlocking {
        let transport = ScriptedTransport(responses: [])
        let delegate = RecordingFlowDelegate()
        let flow = RelayFlowConnection(flowId: 10, destination: .ipv4("1.1.1.1", 443),
                                       secret: flowSecret, transport: transport, delegate: delegate)
        let accepted = flow.enqueueFromCore(Data(repeating: 1, count: 256 * 1024))
        let refused = flow.enqueueFromCore(Data([2]))
        let buffered = flow.bufferedOutboundBytes
        r.check(accepted, "256 KiB accepted")
        r.check(!refused, "one byte over limit refused (backpressure)")
        r.check(buffered == 256 * 1024, "buffer does not grow past limit")
    }

    // RelayDNSClient rejects a HELLO_OK whose client nonce does not match the (random) one it sent.
    runBlocking {
        let query = dnsQueryPacket(txid: 0x1234)
        let sn: UInt64 = 0x1122334455667788
        let client = RelayDNSClient(secret: flowSecret, transportFactory: {
            ScriptedTransport(responses: [serverFrame(.helloOk, clientNonce: 0, serverNonce: sn)])
        }, now: { 1_700_000_000 })
        var threw = false
        do { _ = try await client.query(query, timeout: .seconds(1)) } catch { threw = true }
        r.check(threw, "DNS client rejects a HELLO_OK with a mismatched client nonce")
    }

    r.finish("relay-flow")
}
