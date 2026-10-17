import DroidBridgeShared
import Foundation

private func associationBytes(_ hex: String) -> Data {
    var result = Data(), cursor = hex.startIndex
    while cursor < hex.endIndex {
        let end = hex.index(cursor, offsetBy: 2)
        result.append(UInt8(hex[cursor..<end], radix: 16)!)
        cursor = end
    }
    return result
}
func runUDPAssociationChecks(_ r: CheckRunner) {
    do {
        let peer = try UDPAssociationPeer(address: Data([192,0,2,1]), port: 2222)
        let fixture = associationBytes("000300041234567808ae0000c0000201000000000000000000000000616263")
        let packet = UDPAssociationFrame(peer: peer, payload: Data("abc".utf8), inbound: false, sequence: 0x12345678)
        r.check(try packet.encoded() == fixture, "association IPv4 literal matches Kotlin wire fixture")
        r.check(try UDPAssociationFrame.decode(fixture) == packet, "association decodes address and payload")
        let v6 = associationBytes("00000106ffffffff01bb000020010db8000000000000000000000001")
        let decoded = try UDPAssociationFrame.decode(v6)
        r.check(decoded.payload.isEmpty && decoded.inbound && decoded.peer.family == 6 && decoded.peer.port == 443 && decoded.sequence == .max, "association IPv6 zero payload fixture")
        r.check(try decoded.encoded() == v6, "association IPv6 encoding matches fixture")
        r.check(try DbpCodec.encodeOpenUDPAssociation(family: 4) == associationBytes("04000078"), "association literal OPEN")
        for (offset, byte) in [(0,UInt8(5)),(2,2),(3,5),(8,0),(10,1),(11,1),(16,1)] {
            var bad = fixture; bad[offset] = byte
            if offset == 8 { bad[9] = 0 }
            r.check((try? UDPAssociationFrame.decode(bad)) == nil, "association rejects malformed header at \(offset)")
        }
        r.check((try? UDPAssociationFrame.decode(Data(fixture.dropLast()))) == nil, "association rejects truncated payload")
        r.check((try? DbpCodec.encodeOpenUDPAssociation(family: 5)) == nil, "association rejects invalid family")
        r.check((try? DbpCodec.encodeOpenUDPAssociation(family: 4, idle: 29)) == nil, "association rejects idle below bound")
        let second = try UDPAssociationPeer(address: Data([192,0,2,2]), port: 3333)
        var index = UDPAssociationIndex()
        let first = index.attach(flow: 1, sourcePort: 5000, peer: peer, sourceAddress: Data([198,18,0,2]))
        let same = index.attach(flow: 2, sourcePort: 5000, peer: second, sourceAddress: Data([198,18,0,2]))
        let other = index.attach(flow: 3, sourcePort: 5001, peer: peer, sourceAddress: Data([198,18,0,2]))
        let v6peer = try UDPAssociationPeer(address: Data(repeating: 1, count: 16), port: 443)
        let v6first = index.attach(flow: 5, sourcePort: 5000, peer: v6peer, sourceAddress: Data(repeating: 2, count: 16))
        let v6second = index.attach(flow: 6, sourcePort: 5000, peer: v6peer, sourceAddress: Data(repeating: 3, count: 16))
        r.check(v6first.token != v6second.token, "same port on different IPv6 source addresses cannot share socket")
        r.check(first.created && !same.created && same.token == first.token && other.token != first.token, "same source shares transport across peers, different source is isolated")
        r.check(index.flow(token: first.token, peer: second) == 2 && index.flow(token: other.token, peer: second) == nil, "replies route only to matching source association and peer")
        r.check(index.detach(flow: 1)?.last == false, "removing one peer retains association")
        r.check(index.detach(flow: 2)?.last == true, "last peer retires association")
        let replacement = index.attach(flow: 4, sourcePort: 5000, peer: peer, sourceAddress: Data([198,18,0,2]))
        r.check(index.remove(token: first.token).isEmpty && index.binding(flow: 4)?.token == replacement.token, "delayed old close cannot remove replacement")
        r.check(index.removeAll().sorted() == [3,4,5,6] && index.binding(flow: 4) == nil, "network generation clears every association")
        let queue = UDPAssociationQueue()
        queue.register(flow: 1, peer: peer); queue.register(flow: 2, peer: second)
        queue.append(flow: 1, payload: Data([9])); queue.append(flow: 2, payload: Data())
        queue.remove(flow: 1)
        r.check(queue.pop()?.peer == second && queue.pop() == nil, "queued retired peer packets cannot reach reused association")
        for i in 0..<70 { queue.append(flow: 2, payload: Data([UInt8(i)])) }
        r.check(queue.drops == 6 && queue.pop()?.payload == Data([6]), "association queue bounded to 64 packets with oldest dropped")
        queue.append(flow: 2, payload: Data(count: 1233))
        r.check(queue.drops == 7, "association oversized outbound counted")
        queue.close(); queue.register(flow: 3, peer: peer); queue.append(flow: 3, payload: Data())
        r.check(queue.pop() == nil, "closed association queue cannot reopen")
    } catch { r.check(false, "UDP association: \(error)") }
    r.finish("udp-association")
}

private let associationSecret = Data(repeating: 7, count: 32)
private actor AssociationTransport: RelayTransport {
    enum Mode { case normal, blockedOpen, badAuth, wrongDirection, wrongFamily, blockedSend }
    let mode: Mode
    var raw: [Data] = []
    var opens = 0
    var cancelled = false
    private var inbox = Data()
    private var reader: (Int, CheckedContinuation<Data, Error>)?
    private var writer: CheckedContinuation<Void, Error>?
    init(_ mode: Mode = .normal) { self.mode = mode }
    func start() async throws { if cancelled { throw CancellationError() } }
    func send(_ data: Data) async throws {
        guard !cancelled else { throw CancellationError() }
        guard data.starts(with: Data("DBP1".utf8)) else {
            raw.append(data)
            if mode == .blockedSend { try await withCheckedThrowingContinuation { writer = $0 } }
            return
        }
        let (request, _) = try DbpCodec.decodeHeader(data)
        let payload: Data
        let type: DbpMessageType
        if request.type == .hello { type = .helloOk; payload = Data() }
        else {
            guard request.type == .openUDPAssociation, Data(data.dropFirst(64)) == Data([4,0,0,120]) else { throw DroidBridgeError.relayProtocol("association expected") }
            opens += 1
            if mode == .blockedOpen { return }
            type = .openUDPOk; payload = Data([0,0,0,1,0,120,4,208])
        }
        let response = DbpHeader(type: type, clientNonce: request.clientNonce, serverNonce: 17, unixTime: request.unixTime)
        var frame = DbpCodec.frame(secret: associationSecret, header: response, payload: payload)
        if mode == .badAuth && request.type != .hello { frame[32] ^= 1 }
        inject(frame)
    }
    func inject(_ data: Data) {
        inbox.append(data)
        if let (count, continuation) = reader, inbox.count >= count {
            reader = nil; let packet = Data(inbox.prefix(count)); inbox.removeFirst(count)
            continuation.resume(returning: packet)
        }
    }
    func receiveExactly(_ count: Int) async throws -> Data {
        if cancelled { throw CancellationError() }
        if inbox.count >= count { let d = Data(inbox.prefix(count)); inbox.removeFirst(count); return d }
        return try await withCheckedThrowingContinuation { reader = (count, $0) }
    }
    func receive(maxLength: Int) async throws -> Data { try await receiveExactly(1) }
    func finishSending() async throws {}
    func cancel() async {
        cancelled = true
        if let (_, continuation) = reader { reader = nil; continuation.resume(throwing: CancellationError()) }
        if let continuation = writer { writer = nil; continuation.resume(throwing: CancellationError()) }
    }
}
private final class AssociationRecorder: RelayUDPAssociationDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [UDPAssociationPeer] = []
    private var closures = 0
    func relayUDPAssociationReceived(_ token: UUID, peer: UDPAssociationPeer, data: Data) async { lock.withLock { received.append(peer) } }
    func relayUDPAssociationClosed(_ token: UUID) { lock.withLock { closures += 1 } }
    var peers: [UDPAssociationPeer] { lock.withLock { received } }
    var closeCount: Int { lock.withLock { closures } }
}
func runUDPAssociationRelayChecks(_ r: CheckRunner) async {
    do {
        let first = try UDPAssociationPeer(address: Data([1,1,1,1]), port: 3478)
        let second = try UDPAssociationPeer(address: Data([8,8,8,8]), port: 3478)
        let transport = AssociationTransport(), delegate = AssociationRecorder()
        let conn = RelayUDPAssociationConnection(token: UUID(), family: 4, secret: associationSecret, transport: transport, delegate: delegate)
        conn.register(flow: 1, peer: first); conn.register(flow: 2, peer: second)
        conn.enqueueFromCore(flow: 1, data: Data([1])); conn.enqueueFromCore(flow: 2, data: Data())
        try await conn.start()
        for _ in 0..<100 { if await transport.raw.count == 2 { break }; try await Task.sleep(for: .milliseconds(2)) }
        let sent = try await transport.raw.map { try UDPAssociationFrame.decode($0) }
        let opens = await transport.opens
        r.check(opens == 1 && sent.map(\.peer) == [first,second] && sent[1].payload.isEmpty, "two destinations share one authenticated stream and retain zero datagrams")
        await transport.inject(try UDPAssociationFrame(peer: second, payload: Data(), inbound: true, sequence: 0).encoded())
        for _ in 0..<100 { if delegate.peers.count == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
        r.check(delegate.peers == [second], "association inbound preserves peer address for engine routing")
        await conn.close(); await conn.close()
        r.check(delegate.closeCount == 1, "association close exactly once")
        for mode in [AssociationTransport.Mode.blockedOpen, .badAuth, .wrongDirection, .wrongFamily, .blockedSend] {
            let wire = AssociationTransport(mode), recorder = AssociationRecorder()
            let connection = RelayUDPAssociationConnection(token: UUID(), family: 4, secret: associationSecret, transport: wire, delegate: recorder)
            connection.register(flow: 1, peer: first)
            connection.enqueueFromCore(flow: 1, data: Data([1]))
            do { try await connection.start(timeout: .milliseconds(30)) } catch {}
            if mode == .wrongDirection || mode == .wrongFamily {
                let peer = mode == .wrongFamily ? try UDPAssociationPeer(address: Data(repeating: 1,count: 16),port: 9) : first
                await wire.inject(try UDPAssociationFrame(peer: peer, payload: Data(), inbound: mode != .wrongDirection, sequence: 0).encoded())
            }
            if mode == .blockedSend {
                await wire.inject(try UDPAssociationFrame(peer: first, payload: Data(), inbound: true, sequence: 0).encoded())
                for _ in 0..<100 { if recorder.peers.count == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
                r.check(recorder.peers == [first], "association blocked upload does not stop inbound UDP")
                await connection.close()
            }
            for _ in 0..<100 { if recorder.closeCount == 1 { break }; try await Task.sleep(for: .milliseconds(2)) }
            let cancelled = await wire.cancelled
            r.check(cancelled && recorder.closeCount == 1 && (mode == .blockedSend || recorder.peers.isEmpty), "association auth/direction/family/deadline/blocked-send cleanup")
        }
        let wire = AssociationTransport(), recorder = AssociationRecorder()
        let closed = RelayUDPAssociationConnection(token: UUID(), family: 4, secret: associationSecret, transport: wire, delegate: recorder)
        await closed.close()
        do { try await closed.start(); r.check(false, "closed association must not restart") } catch {}
        let opensAfterClose = await wire.opens
        r.check(opensAfterClose == 0, "close before start does not open socket")
    } catch { r.check(false, "UDP association relay: \(error)") }
    r.finish("udp-association-relay")
}
