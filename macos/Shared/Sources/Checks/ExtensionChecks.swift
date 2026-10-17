import DroidBridgeShared
import Foundation

func runExtensionChecks(_ r: CheckRunner) async {
    do {
        let v6 = try DbpCodec.encodeOpenTcp(destination: .ipv6("2606:4700:4700::1111", 443))
        r.check(v6.count == 20 && v6[0] == 2 && v6[3] == 16, "IPv6 TCP literal encoding")
        let udp = try DbpCodec.encodeOpenUDP(destination: .ipv4("1.1.1.1", 443))
        r.check(udp == Data([1,1,187,4,1,1,1,1,0,120]), "UDP literal and idle wire bytes")
        let empty = try DatagramFrame(payload: Data(), inbound: true, sequence: .max).encoded()
        let decoded = try DatagramFrame.decode(empty)
        r.check(decoded.payload.isEmpty && decoded.inbound && decoded.sequence == .max, "zero length UDP preserves datagram and sequence")
        for malformed in [Data([4,209,1,0,0,0,0,0]), Data([0,0,2,0,0,0,0,0]), Data([0,0,1,1,0,0,0,0]), Data([0,1,1,0,0,0,0,0])] {
            r.check((try? DatagramFrame.decode(malformed)) == nil, "UDP rejects oversize flags reserved and truncated frames")
        }
        var body = Data(repeating: 0, count: 59)
        body[0] = 1; body[8] = 15; body[16] = 7; body[17] = 65; body[18] = 65
        let caps = try DbpCodec.decodeCapabilities(Data([0,59]) + body)
        r.check(caps.flags == 15 && caps.cellularGeneration == 7 && caps.ipv4TTL == 65 && caps.supports(.udp6), "capability offsets and flags")
        r.check((try? DbpCodec.decodeCapabilities(Data([0,58]) + body)) == nil, "capabilities exact length enforced")
        r.check((try? DbpCodec.payloadRemaining(.capabilitiesResponse, prefix: [1,1])) == nil, "capabilities allocation bound")
        let wakes = DatagramQueue()
        let firstWake = wakes.append(Data([1])), secondWake = wakes.append(Data([2]))
        r.check(firstWake && !secondWake, "UDP enqueuing coalesces pending wake tasks")
        let queue = DatagramQueue()
        for value in 0..<70 { queue.append(Data([UInt8(value)])) }
        r.check(queue.count == 64 && queue.drops == 6 && queue.pop() == Data([6]), "UDP queue drops oldest at 64 packets")
        queue.close()
        queue.append(Data([99]))
        r.check(queue.count == 0 && queue.pop() == nil, "closed UDP queue releases and rejects packets")
    } catch { r.check(false, "extension codec: \(error)") }
    r.finish("extensions")
}

private let extensionSecret = Data(repeating: 3, count: 32)
private actor ExtensionTransport: RelayTransport {
    enum Mode: Sendable { case normal, badNonce, badHMAC, badHMACSlowClose, truncatedCaps, legacy, blockedHello, blockedQuery, blockedSend, wrongDirection }
    let mode: Mode
    var started = false
    var cancelled = false
    var sent: [Data] = []
    private var blockedSend: CheckedContinuation<Void, Error>?
    private var inbox = Data()
    private var waiting: (Int, CheckedContinuation<Data, Error>)?
    init(_ mode: Mode = .normal) { self.mode = mode }
    func start() async throws { guard !cancelled else { throw CancellationError() }; started = true }
    func send(_ data: Data) async throws {
        guard !cancelled else { throw CancellationError() }
        sent.append(data)
        guard data.starts(with: Data("DBP1".utf8)) else {
            if mode == .blockedSend { try await withCheckedThrowingContinuation { blockedSend = $0 } }
            return
        }
        let (request, _) = try DbpCodec.decodeHeader(data)
        if (mode == .blockedHello && request.type == .hello) || (mode == .blockedQuery && request.type != .hello) { return }
        if mode == .legacy && request.type == .capabilities { await cancel(); return }
        let type: DbpMessageType
        var payload = Data()
        switch request.type {
        case .hello: type = .helloOk
        case .capabilities:
            type = .capabilitiesResponse
            var body = Data(repeating: 0, count: 59); body[0] = 1; body[8] = 15; body[16] = 42
            payload = Data([0,59]) + body
        case .openUDP: type = .openUDPOk; payload = Data([0,0,0,7,0,120,4,208])
        case .dnsQuery: type = .dnsResponse; payload = Data(data.dropFirst(64))
        case .icmpEcho:
            type = .icmpResponse
            let p = [UInt8](data.dropFirst(64))
            payload = Data(p[4..<8]) + Data([p[0],64,p[2],p[3]]) + Data(count: 8) + Data(p[8..<24]) + Data(p.dropFirst(24))
        default: throw DroidBridgeError.relayProtocol("unexpected request")
        }
        let wrongNonce = mode == .badNonce && request.type != .hello
        let header = DbpHeader(type: type, clientNonce: wrongNonce ? 0 : request.clientNonce, serverNonce: 99, unixTime: request.unixTime)
        var response = DbpCodec.frame(secret: extensionSecret, header: header, payload: payload)
        if (mode == .badHMAC || mode == .badHMACSlowClose) && request.type != .hello { response[32] ^= 1 }
        inbox.append(mode == .truncatedCaps && request.type == .capabilities ? Data(response.prefix(64)) : response)
        if request.type == .openUDP {
            inbox.append(try DatagramFrame(payload: Data(), inbound: mode != .wrongDirection, sequence: 0).encoded())
            inbox.append(try DatagramFrame(payload: Data(repeating: 9, count: 1232), inbound: true, sequence: 2).encoded())
        }
        resumeIfReady()
    }
    private func resumeIfReady() {
        if let (count, continuation) = waiting, inbox.count >= count {
            waiting = nil
            let result = Data(inbox.prefix(count)); inbox.removeFirst(count)
            continuation.resume(returning: result)
        }
    }
    func receiveExactly(_ count: Int) async throws -> Data {
        guard !cancelled else { throw DroidBridgeError.relayProtocol("peer closed") }
        if inbox.count >= count { let d = Data(inbox.prefix(count)); inbox.removeFirst(count); return d }
        if mode == .truncatedCaps { throw DroidBridgeError.relayProtocol("peer closed") }
        return try await withCheckedThrowingContinuation { waiting = (count, $0) }
    }
    func receive(maxLength: Int) async throws -> Data { try await receiveExactly(1) }
    func finishSending() async throws {}
    func cancel() async {
        let wasWaiting = waiting != nil
        cancelled = true
        if let blockedSend { self.blockedSend = nil; blockedSend.resume(throwing: CancellationError()) }
        if let (_, continuation) = waiting { waiting = nil; continuation.resume(throwing: DroidBridgeError.relayProtocol("peer closed")) }
        if wasWaiting && (mode == .blockedQuery || mode == .blockedHello) { try? await Task.sleep(for: .milliseconds(10)) }
        if mode == .badHMACSlowClose { try? await Task.sleep(for: .milliseconds(60)) }
    }
    var rawFrames: [Data] { sent.filter { !$0.starts(with: Data("DBP1".utf8)) } }
    var waitingForInput: Bool { waiting != nil }
}
private final class DatagramRecorder: RelayDatagramDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    private var closures = 0
    func relayDatagramReceived(_ flow: UInt32, data: Data) { lock.withLock { packets.append(data) } }
    func relayDatagramClosed(_ flow: UInt32) { lock.withLock { closures += 1 } }
    var received: [Data] { lock.withLock { packets } }
    var closedCount: Int { lock.withLock { closures } }
}
func runExtensionRelayChecks(_ r: CheckRunner) async {
    for mode in [ExtensionTransport.Mode.normal, .badNonce, .badHMAC, .truncatedCaps, .legacy] {
        let transport = ExtensionTransport(mode)
        let client = RelayExtensionClient(secret: extensionSecret, transportFactory: { transport })
        do {
            let caps = try await client.capabilities()
            r.check((mode == .normal && caps.cellularGeneration == 42) || (mode == .legacy && caps == .legacy), "capabilities authenticated or explicit legacy")
        } catch { r.check(mode == .badNonce || mode == .badHMAC || mode == .truncatedCaps, "capabilities rejects HMAC/nonce/truncation without downgrading") }
        let cancelled = await transport.cancelled
        r.check(cancelled, "short capability transport closes")
    }
    let transport = ExtensionTransport()
    let delegate = DatagramRecorder()
    let flow = RelayDatagramConnection(flowId: 7, destination: .ipv6("2606:4700::1111",443), secret: extensionSecret, transport: transport, delegate: delegate)
    for value in 0..<70 { flow.enqueueFromCore(Data([UInt8(value)])) }
    do { try await flow.start() } catch { r.check(false, "UDP start: \(error)") }
    try? await Task.sleep(for: .milliseconds(20))
    let frames = await transport.rawFrames
    let first = frames.first.flatMap { try? DatagramFrame.decode($0) }
    r.check(frames.count == 64 && first?.payload == Data([6]) && first?.sequence == 0, "UDP initial queue drains in order after authenticated OPEN")
    r.check(delegate.received == [Data(),Data(repeating: 9,count: 1232)], "UDP receives empty and maximum packet distinctly")
    let gaps = await flow.sequenceGaps
    r.check(gaps == 1 && flow.drops == 6, "UDP sequence gaps and queue drops tracked")
    await flow.close(); await flow.close()
    r.check(delegate.closedCount == 1, "UDP close is idempotent")
    for mode in [ExtensionTransport.Mode.badNonce, .badHMAC, .wrongDirection, .blockedHello] {
        let transport = ExtensionTransport(mode), recorder = DatagramRecorder()
        let flow = RelayDatagramConnection(flowId: 1, destination: .ipv4("1.1.1.1",443), secret: extensionSecret, transport: transport, delegate: recorder)
        do { try await flow.start(timeout: .milliseconds(25)) } catch {}
        try? await Task.sleep(for: .milliseconds(10))
        let cancelled = await transport.cancelled
        r.check(cancelled && recorder.received.isEmpty && recorder.closedCount == 1, "UDP bad auth/direction/deadline closes without delivery")
    }
    let closedTransport = ExtensionTransport(), closedRecorder = DatagramRecorder()
    let never = RelayDatagramConnection(flowId: 1, destination: .ipv4("1.1.1.1",443), secret: extensionSecret, transport: closedTransport, delegate: closedRecorder)
    await never.close()
    do { try await never.start(); r.check(false,"closed UDP must not reopen") } catch {}
    let started = await closedTransport.started
    r.check(!started, "UDP cancelled before start never opens transport")
    for mode in [ExtensionTransport.Mode.badNonce, .blockedQuery] {
        let transport = ExtensionTransport(mode)
        let client = RelayDNSClient(secret: extensionSecret, transportFactory: { transport })
        do { _ = try await client.query(Data(count: 12), timeout: .milliseconds(25)); r.check(false,"DNS bad nonce/deadline") } catch {}
        let cancelled = await transport.cancelled
        r.check(cancelled, "DNS nonce failure/deadline actively closes I/O")
    }
    let pingTransport = ExtensionTransport()
    let client = RelayExtensionClient(secret: extensionSecret, transportFactory: { pingTransport })
    do {
        let echoed = try await client.echo(request: 7, family: 4, destination: Data([1,1,1,1]), ttl: 64, payload: Data([3,4]))
        r.check(echoed == Data([3,4]), "ICMP source family request and payload verified")
    } catch { r.check(false,"ICMP authenticated echo: \(error)") }
    let pressured = ExtensionTransport(.blockedSend), pressuredRecorder = DatagramRecorder()
    let pressuredFlow = RelayDatagramConnection(flowId: 4, destination: .ipv4("1.1.1.1",443), secret: extensionSecret, transport: pressured, delegate: pressuredRecorder)
    pressuredFlow.enqueueFromCore(Data([1]))
    let opening = Task { try? await pressuredFlow.start() }
    try? await Task.sleep(for: .milliseconds(30))
    r.check(pressuredRecorder.received.count == 2, "UDP uploads under backpressure do not block downloads")
    await pressuredFlow.close(); await opening.value
    let blocked = ExtensionTransport(.blockedQuery)
    let blockedClient = RelayExtensionClient(secret: extensionSecret, transportFactory: { blocked })
    do { _ = try await blockedClient.capabilities(timeout: .milliseconds(20)); r.check(false, "capability timeout must not downgrade to legacy") }
    catch { r.check(true, "capability timeout must not downgrade to legacy") }
    let blockedHello = ExtensionTransport(.blockedHello)
    let helloClient = RelayExtensionClient(secret: extensionSecret, transportFactory: { blockedHello })
    do {
        _ = try await helloClient.capabilities(timeout: .milliseconds(20))
        r.check(false, "capability HELLO deadline must fail")
    } catch {
        r.check((error as? DroidBridgeError) == .relayTimedOut,
                "capability HELLO deadline keeps timeout cause when cancellation wakes reader with EOF")
    }
    let cancelledHello = ExtensionTransport(.blockedHello)
    let cancelledClient = RelayExtensionClient(secret: extensionSecret, transportFactory: { cancelledHello })
    let query = Task { try await cancelledClient.capabilities(timeout: .seconds(2)) }
    let waitDeadline = ContinuousClock.now + .seconds(1)
    while !(await cancelledHello.waitingForInput), ContinuousClock.now < waitDeadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    let waitingForCancellation = await cancelledHello.waitingForInput
    r.check(waitingForCancellation, "cancelled capability test reaches blocked HELLO read")
    query.cancel()
    do { _ = try await query.value; r.check(false, "cancelled capability must not succeed") }
    catch { r.check(error is CancellationError, "caller cancellation remains cancellation, not timeout or EOF") }
    let slowClose = ExtensionTransport(.badHMACSlowClose)
    let slowCloseClient = RelayExtensionClient(secret: extensionSecret, transportFactory: { slowClose })
    do { _ = try await slowCloseClient.capabilities(timeout: .milliseconds(20)); r.check(false, "bad HMAC must fail") }
    catch { r.check((error as? DroidBridgeError) == .relayAuthenticationFailed,
                    "pre-deadline authentication failure survives cleanup past the deadline") }
    r.finish("extension-relay")
}

private struct ExtensionFixtures: Decodable {
    let secret_hex: String
    let vectors: [ControlVector]
    let datagrams: [DatagramVector]
    struct ControlVector: Decodable { let name: String; let packet_hex: String; let payload_hex: String }
    struct DatagramVector: Decodable { let wire_hex: String; let payload_hex: String; let inbound: Bool; let sequence: UInt32 }
}
private func fixtureBytes(_ hex: String) -> Data {
    var result = Data(); var index = hex.startIndex
    while index < hex.endIndex { let next = hex.index(index,offsetBy: 2); result.append(UInt8(hex[index..<next],radix:16)!); index = next }
    return result
}
func runExtensionFixtureChecks(_ r: CheckRunner) {
    do {
        guard let json = DbpFixtures.extensionsJSON() else { throw DroidBridgeError.relayProtocol("missing extension fixture") }
        let fixture = try JSONDecoder().decode(ExtensionFixtures.self, from: json)
        for vector in fixture.vectors {
            let packet = fixtureBytes(vector.packet_hex), payload = fixtureBytes(vector.payload_hex)
            let (header, _) = try DbpCodec.decodeHeader(packet)
            r.check(DbpCodec.frame(secret: fixtureBytes(fixture.secret_hex), header: header, payload: payload) == packet, "canonical \(vector.name) authenticated bytes")
            let prefix = DbpCodec.payloadPrefixLength(header.type)
            let remaining = try DbpCodec.payloadRemaining(header.type, prefix: Array(payload.prefix(prefix)))
            r.check(prefix + remaining == payload.count, "canonical \(vector.name) bounded reader")
            switch vector.name {
            case "capabilities_response":
                let caps = try DbpCodec.decodeCapabilities(payload)
                r.check(caps.flags == 0x27f && caps.uploadBytesPerSecond == 131072 && caps.downloadBytesPerSecond == 262144 && caps.burstBytes == 65536 && caps.nat64PrefixLength == 96 && caps.activeUDP == 7 && caps.udpDrops == 9, "canonical full capability profile offsets")
            case "open_udp_association4": let encoded = try DbpCodec.encodeOpenUDPAssociation(family: 4); r.check(encoded == payload, "canonical association IPv4 OPEN")
            case "open_udp_association6": let encoded = try DbpCodec.encodeOpenUDPAssociation(family: 6); r.check(encoded == payload, "canonical association IPv6 OPEN")
            case "open_tcp_ipv6": let encoded = try DbpCodec.encodeOpenTcp(destination: .ipv6("2606:4700:4700::1111",443)); r.check(encoded == payload, "canonical IPv6 TCP")
            case "open_udp_ipv4": let encoded = try DbpCodec.encodeOpenUDP(destination: .ipv4("1.1.1.1",443)); r.check(encoded == payload, "canonical IPv4 UDP")
            case "open_udp_ipv6": let encoded = try DbpCodec.encodeOpenUDP(destination: .ipv6("2606:4700:4700::1111",443)); r.check(encoded == payload, "canonical IPv6 UDP")
            default: break
            }
        }
        for vector in fixture.datagrams {
            let frame = try DatagramFrame.decode(fixtureBytes(vector.wire_hex))
            let encoded = try frame.encoded()
            r.check(frame.payload == fixtureBytes(vector.payload_hex) && frame.inbound == vector.inbound && frame.sequence == vector.sequence && encoded == fixtureBytes(vector.wire_hex), "canonical datagram framing")
        }
    } catch { r.check(false,"canonical extension fixture: \(error)") }
    r.finish("extension-fixtures")
}
