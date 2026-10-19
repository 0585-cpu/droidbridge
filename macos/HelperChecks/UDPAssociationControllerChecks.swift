import DroidBridgeShared
import Foundation

private let controllerUDPSecret = Data(repeating: 19, count: 32)

private actor ControllerCapabilityScript {
    private var results: [Result<UInt8, DroidBridgeError>] = []
    private var fallback: Result<UInt8, DroidBridgeError> = .success(1)
    private(set) var calls = 0
    func set(_ values: [Result<UInt8, DroidBridgeError>], then fallback: Result<UInt8, DroidBridgeError> = .success(1)) {
        results = values; self.fallback = fallback
    }
    func nextGeneration() throws -> UInt8 {
        calls += 1
        return try (results.isEmpty ? fallback : results.removeFirst()).get()
    }
}

private struct ControllerUDPCheckError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func udpRequire(_ value: Bool, _ message: String) throws {
    if !value { throw ControllerUDPCheckError(message: message) }
}

private func udpEventually(_ message: String, _ condition: () async throws -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw ControllerUDPCheckError(message: "Timed out: \(message)")
}

/// A single pending utun read per session, with old completions retained for restart checks.
private final class ControllerUDPPackets: PacketSource, @unchecked Sendable {
    private let lock = NSLock()
    private var readers: [@Sendable ([Data]) -> Void] = []
    private var output: [Data] = []
    func read(_ handler: @escaping @Sendable ([Data]) -> Void) { lock.withLock { readers.append(handler) } }
    func write(_ packets: [Data]) { lock.withLock { output.append(contentsOf: packets) } }
    var written: [Data] { lock.withLock { output } }
    func clearWritten() { lock.withLock { output.removeAll() } }
    func submit(_ packet: Data, oldest: Bool = false) {
        let handler = lock.withLock { () -> (@Sendable ([Data]) -> Void)? in
            guard !readers.isEmpty else { return nil }
            return oldest ? readers.removeFirst() : readers.removeLast()
        }
        handler?([packet])
    }
}

private struct ControllerUDPWireState: Sendable {
    let command: DbpMessageType?
    let opens: Int
    let openPayload: Data
    let packets: [Data]
    let cancelRequested: Bool
    let cancelCompleted: Bool
}

/// Only the external relay byte transport is substituted. The real session authenticates these
/// responses, opens its normal association/datagram actors and dispatches into the real C engine.
private actor ControllerUDPWire: RelayTransport {
    let associationSupported: Bool
    private let capabilityScript: ControllerCapabilityScript?
    private var command: DbpMessageType?
    private var opens = 0
    private var openPayload = Data()
    private var packets: [Data] = []
    private var inbox = Data()
    private var reader: (Int, CheckedContinuation<Data, Error>)?
    private var cancelRequested = false
    private var cancelled = false
    private var holdCancel = false
    private var cancelWaiters: [CheckedContinuation<Void, Never>] = []
    init(associationSupported: Bool, capabilityScript: ControllerCapabilityScript? = nil) {
        self.associationSupported = associationSupported; self.capabilityScript = capabilityScript
    }
    var state: ControllerUDPWireState {
        ControllerUDPWireState(command: command, opens: opens, openPayload: openPayload, packets: packets,
                               cancelRequested: cancelRequested, cancelCompleted: cancelled)
    }
    func start() async throws { if cancelled { throw CancellationError() } }
    func send(_ data: Data) async throws {
        guard !cancelled else { throw CancellationError() }
        guard data.starts(with: Data("DBP1".utf8)) else { packets.append(data); return }
        let (request, hmac) = try DbpCodec.decodeHeader(data)
        let payload = Data(data.dropFirst(64))
        guard DbpCodec.verifyHMAC(secret: controllerUDPSecret, header: request, payload: payload, hmac: hmac),
              request.serverNonce == (request.type == .hello ? 0 : 73) else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        let type: DbpMessageType, response: Data
        switch request.type {
        case .hello:
            type = .helloOk; response = Data()
        case .capabilities:
            command = request.type; type = .capabilitiesResponse
            let generation = try await capabilityScript?.nextGeneration() ?? 1
            // Literal 61-byte capabilities: UDP4, optionally association, generation one.
            var caps = Data(count: 61)
            caps[1] = 59; caps[2] = 1; caps[9] = associationSupported ? 4 : 0
            caps[10] = 2; caps[18] = generation; caps[19] = 64; caps[20] = 64
            response = caps
        case .openUDPAssociation, .openUDP:
            opens += 1
            command = request.type; openPayload = payload
            type = .openUDPOk; response = Data([0, 0, 0, 1, 0, 120, 5, 192]) // max payload 1472
        default:
            throw ControllerUDPCheckError(message: "Unexpected controller relay command \(request.type)")
        }
        inject(DbpCodec.frame(secret: controllerUDPSecret,
            header: DbpHeader(type: type, clientNonce: request.clientNonce, serverNonce: 73,
                              unixTime: request.unixTime), payload: response))
    }
    func inject(_ bytes: Data) {
        inbox.append(bytes)
        if let (count, continuation) = reader, inbox.count >= count {
            reader = nil
            let bytes = Data(inbox.prefix(count)); inbox.removeFirst(count)
            continuation.resume(returning: bytes)
        }
    }
    func receiveExactly(_ count: Int) async throws -> Data {
        guard !cancelled else { throw CancellationError() }
        if inbox.count >= count {
            let bytes = Data(inbox.prefix(count)); inbox.removeFirst(count); return bytes
        }
        return try await withCheckedThrowingContinuation { reader = (count, $0) }
    }
    func receive(maxLength: Int) async throws -> Data { try await receiveExactly(1) }
    func delayCancellation() { holdCancel = true }
    func releaseCancellation() {
        holdCancel = false
        let waiters = cancelWaiters; cancelWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
    func finishSending() async throws {}
    func cancel() async {
        cancelRequested = true
        if holdCancel { await withCheckedContinuation { cancelWaiters.append($0) } }
        cancelled = true
        if let (_, continuation) = reader { reader = nil; continuation.resume(throwing: CancellationError()) }
    }
}

private final class ControllerUDPRelays: @unchecked Sendable {
    private let lock = NSLock()
    private var wires: [ControllerUDPWire] = []
    let associationSupported: Bool
    private let capabilityScript: ControllerCapabilityScript?
    init(associationSupported: Bool, capabilityScript: ControllerCapabilityScript? = nil) {
        self.associationSupported = associationSupported; self.capabilityScript = capabilityScript
    }
    func make() -> any RelayTransport {
        let wire = ControllerUDPWire(associationSupported: associationSupported, capabilityScript: capabilityScript)
        lock.withLock { wires.append(wire) }
        return wire
    }
    func opened() async -> [(ControllerUDPWire, ControllerUDPWireState)] {
        let all = lock.withLock { wires }
        var result: [(ControllerUDPWire, ControllerUDPWireState)] = []
        for wire in all {
            let state = await wire.state
            if state.command == .openUDPAssociation || state.command == .openUDP { result.append((wire, state)) }
        }
        return result
    }
}

private func udpWord(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
    UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
}
private func udpChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for index in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[index]) << 8
        if index + 1 < bytes.count { sum += UInt32(bytes[index + 1]) }
    }
    while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
}
private func udpSetWord(_ value: UInt16, _ bytes: inout [UInt8], _ offset: Int) {
    bytes[offset] = UInt8(value >> 8); bytes[offset + 1] = UInt8(value & 255)
}
private func controllerUDPPacket(sourcePort: UInt16, peer: [UInt8], port: UInt16, marker: UInt8) -> Data {
    var packet: [UInt8] = [0x45, 0, 0, 29, 0, 1, 0, 0, 64, 17, 0, 0,
                          198, 18, 0, 2] + peer + [0, 0, 0, 0, 0, 9, 0, 0, marker]
    udpSetWord(sourcePort, &packet, 20); udpSetWord(port, &packet, 22)
    udpSetWord(udpChecksum(Array(packet.prefix(20))), &packet, 10)
    let checksum = udpChecksum(Array(packet[12..<20]) + [0, 17, 0, 9] + Array(packet[20...]))
    udpSetWord(checksum == 0 ? 65535 : checksum, &packet, 26)
    return Data(packet)
}
private func checkControllerUDPReply(_ packet: Data, peer: [UInt8], peerPort: UInt16,
                                     sourcePort: UInt16, marker: UInt8) throws {
    let bytes = [UInt8](packet)
    try udpRequire(bytes.count == 29 && bytes[0] == 0x45 && bytes[9] == 17,
                   "Controller reply must be an IPv4 UDP packet with the one-byte payload")
    try udpRequire(Array(bytes[12..<16]) == peer && Array(bytes[16..<20]) == [198, 18, 0, 2]
                   && udpWord(bytes, 20) == peerPort && udpWord(bytes, 22) == sourcePort
                   && bytes[28] == marker, "Controller must restore the complete original UDP tuple")
    try udpRequire(udpWord(bytes, 2) == 29 && udpWord(bytes, 24) == 9
                   && udpChecksum(Array(bytes.prefix(20))) == 0
                   && udpChecksum(Array(bytes[12..<20]) + [0, 17, 0, 9] + Array(bytes[20...])) == 0,
                   "Controller replies must carry valid IP and UDP lengths/checksums")
}

/// Publish readiness is asynchronous. Retry this one tuple until C admits it; tuple identity means
/// retries cannot manufacture additional OPENs. Later assertions use distinct payload markers.
private func primeControllerUDP(_ controller: TunnelController, _ source: ControllerUDPPackets,
                               _ relays: ControllerUDPRelays, previousOpens: Int, marker: UInt8) async throws {
    try await udpEventually("controller capability negotiation") { controller.capabilities != nil }
    try await udpEventually("C UDP tuple admitted by controller") {
        if await relays.opened().count > previousOpens { return true }
        source.submit(controllerUDPPacket(sourcePort: 6000, peer: [1, 1, 1, 1], port: 3478, marker: marker))
        return false
    }
    try await udpEventually("first controller UDP payload") {
        await relays.opened().contains { $0.1.packets.contains { $0.last == marker } }
    }
}

private func runSharedControllerUDPCheck() async throws {
    let source = ControllerUDPPackets(), relays = ControllerUDPRelays(associationSupported: true)
    let controller = TunnelController(packetSource: source, secret: controllerUDPSecret, transportFactory: { relays.make() })
    defer { controller.stop() }
    try udpRequire(controller.start(), "Association controller starts")
    try await primeControllerUDP(controller, source, relays, previousOpens: 0, marker: 11)
    source.submit(controllerUDPPacket(sourcePort: 6000, peer: [8, 8, 8, 8], port: 3479, marker: 12))
    source.submit(controllerUDPPacket(sourcePort: 6001, peer: [1, 1, 1, 1], port: 3478, marker: 13))
    try await udpEventually("two source endpoints and all three peer payloads") {
        let opened = await relays.opened()
        return controller.activeUDPCount == 3 && [UInt8(11), 12, 13].allSatisfy { marker in
            opened.contains { $0.1.packets.contains { $0.last == marker } }
        }
    }
    let opened = await relays.opened()
    try udpRequire(opened.count == 2 && opened.allSatisfy {
        $0.1.opens == 1 && $0.1.command == .openUDPAssociation && $0.1.openPayload == Data([4, 0, 0, 120])
    }, "Two destination tuples at source 6000 must share one OPEN; source 6001 must use a second")
    let shared = opened.first { $0.1.packets.contains { $0.last == 11 } }!
    let separate = opened.first { $0.1.packets.contains { $0.last == 13 } }!
    let sent = try shared.1.packets.map(UDPAssociationFrame.decode)
    try udpRequire(sent.contains { $0.peer.address == Data([1, 1, 1, 1]) && $0.peer.port == 3478 && $0.payload == Data([11]) }
                   && sent.contains { $0.peer.address == Data([8, 8, 8, 8]) && $0.peer.port == 3479 && $0.payload == Data([12]) }
                   && sent.allSatisfy { !$0.inbound && $0.payload != Data([13]) },
                   "Shared controller stream must preserve destination addresses without mixing source sockets")
    let firstPeer = try UDPAssociationPeer(address: Data([1, 1, 1, 1]), port: 3478)
    let secondPeer = try UDPAssociationPeer(address: Data([8, 8, 8, 8]), port: 3479)
    await shared.0.inject(try UDPAssociationFrame(peer: secondPeer, payload: Data([22]), inbound: true, sequence: 0).encoded())
    await shared.0.inject(try UDPAssociationFrame(peer: firstPeer, payload: Data([21]), inbound: true, sequence: 1).encoded())
    await separate.0.inject(try UDPAssociationFrame(peer: firstPeer, payload: Data([23]), inbound: true, sequence: 0).encoded())
    try await udpEventually("three correctly routed association replies") { source.written.count == 3 }
    for (marker, peer, port, sourcePort) in [(UInt8(21), [UInt8(1), 1, 1, 1], UInt16(3478), UInt16(6000)),
                                           (22, [8, 8, 8, 8], 3479, 6000), (23, [1, 1, 1, 1], 3478, 6001)] {
        guard let packet = source.written.first(where: { $0.last == marker }) else {
            throw ControllerUDPCheckError(message: "Missing controller response \(marker)")
        }
        try checkControllerUDPReply(packet, peer: peer, peerPort: port, sourcePort: sourcePort, marker: marker)
    }

    // Keep old close completion pending until the same tuple exists in a new C engine/session.
    await shared.0.delayCancellation()
    controller.stop()
    try udpRequire(controller.activeUDPCount == 0, "Stop destroys original UDP state")
    try await udpEventually("old association cancellation begins") { await shared.0.state.cancelRequested }
    source.clearWritten()
    try udpRequire(controller.start(), "Association controller restarts")
    source.submit(controllerUDPPacket(sourcePort: 6010, peer: [9, 9, 9, 9], port: 3480, marker: 99), oldest: true)
    try await primeControllerUDP(controller, source, relays, previousOpens: 2, marker: 31)
    let restarted = await relays.opened()
    try udpRequire(restarted.count == 3 && restarted.allSatisfy { $0.1.opens == 1 },
                   "Restart opens a fresh association; stale packet callbacks cannot open flows")
    let replacement = restarted.first { $0.1.packets.contains { $0.last == 31 } }!
    await shared.0.inject(try UDPAssociationFrame(peer: firstPeer, payload: Data([98]), inbound: true, sequence: 2).encoded())
    await shared.0.releaseCancellation()
    try await udpEventually("old delayed cancellation completes") { await shared.0.state.cancelCompleted }
    source.submit(controllerUDPPacket(sourcePort: 6000, peer: [1, 1, 1, 1], port: 3478, marker: 32))
    try await udpEventually("replacement sends after old cancellation") { await replacement.0.state.packets.contains { $0.last == 32 } }
    await replacement.0.inject(try UDPAssociationFrame(peer: firstPeer, payload: Data([33]), inbound: true, sequence: 0).encoded())
    try await udpEventually("replacement receives after old cancellation") { source.written.count == 1 }
    try checkControllerUDPReply(source.written[0], peer: [1, 1, 1, 1], peerPort: 3478, sourcePort: 6000, marker: 33)
    let finalOpens = await relays.opened().count
    try udpRequire(finalOpens == 3 && controller.activeUDPCount == 1,
                   "Late old callbacks cannot retire or reopen the replacement source association")
    print("controller UDP association sharing, reply tuples and restart isolation: passed")
}

private func runLegacyControllerUDPCheck() async throws {
    let source = ControllerUDPPackets(), relays = ControllerUDPRelays(associationSupported: false)
    let controller = TunnelController(packetSource: source, secret: controllerUDPSecret, transportFactory: { relays.make() })
    defer { controller.stop() }
    try udpRequire(controller.start(), "Legacy UDP controller starts")
    try await primeControllerUDP(controller, source, relays, previousOpens: 0, marker: 41)
    source.submit(controllerUDPPacket(sourcePort: 6000, peer: [8, 8, 8, 8], port: 3479, marker: 42))
    try await udpEventually("two legacy per-destination streams") {
        let opened = await relays.opened()
        return opened.count == 2 && opened.contains { $0.1.packets.contains { $0.last == 42 } }
    }
    let opened = await relays.opened()
    try udpRequire(opened.allSatisfy { $0.1.opens == 1 && $0.1.command == .openUDP }
                   && opened.contains { $0.1.openPayload == Data([1, 13, 150, 4, 1, 1, 1, 1, 0, 120]) }
                   && opened.contains { $0.1.openPayload == Data([1, 13, 151, 4, 8, 8, 8, 8, 0, 120]) },
                   "Absent association capability must preserve literal per-destination OPEN_UDP")
    for (wire, state) in opened {
        let sent = try state.packets.map(DatagramFrame.decode)
        try udpRequire(sent.allSatisfy { !$0.inbound && $0.payload.count == 1 }, "Legacy datagram framing remains active")
        let first = state.openPayload[4] == 1
        await wire.inject(try DatagramFrame(payload: Data([first ? 51 : 52]), inbound: true, sequence: 0).encoded())
    }
    try await udpEventually("legacy replies retain their original tuples") { source.written.count == 2 }
    for packet in source.written {
        let first = packet.last == 51
        try checkControllerUDPReply(packet, peer: first ? [1, 1, 1, 1] : [8, 8, 8, 8],
                                    peerPort: first ? 3478 : 3479, sourcePort: 6000, marker: first ? 51 : 52)
    }
    print("controller UDP association capability fallback: passed")
}

func runUDPAssociationControllerChecks() async throws {
    try await runSharedControllerUDPCheck()
    try await runLegacyControllerUDPCheck()
}

func runCapabilityRetentionChecks() async throws {
    try await runCapabilityRetentionCheck(associationSupported: true)
    try await runCapabilityRetentionCheck(associationSupported: false)
    for failure in [DroidBridgeError.relayAuthenticationFailed, .relayProtocol("invalid capabilities")] {
        let script = ControllerCapabilityScript()
        let source = ControllerUDPPackets(), relays = ControllerUDPRelays(associationSupported: true, capabilityScript: script)
        let controller = TunnelController(packetSource: source, secret: controllerUDPSecret,
            transportFactory: { relays.make() }, capabilityPollInterval: .milliseconds(20))
        defer { controller.stop() }
        try udpRequire(controller.start(), "explicit failure controller starts")
        try await primeControllerUDP(controller, source, relays, previousOpens: 0, marker: 71)
        let original = await relays.opened()[0].0
        await script.set([], then: .failure(failure))
        try await udpEventually("explicit failure closes association and blocks capabilities") {
            await original.state.cancelRequested && controller.capabilities == nil
        }
    }
    let script = ControllerCapabilityScript()
    await script.set([], then: .failure(.relayTimedOut))
    let source = ControllerUDPPackets(), relays = ControllerUDPRelays(associationSupported: true, capabilityScript: script)
    let controller = TunnelController(packetSource: source, secret: controllerUDPSecret,
        transportFactory: { relays.make() }, capabilityPollInterval: .milliseconds(20))
    defer { controller.stop() }
    try udpRequire(controller.start(), "initial timeout controller starts")
    try await udpEventually("initial failed negotiation retried") { await script.calls >= 3 }
    source.submit(controllerUDPPacket(sourcePort: 6000, peer: [1, 1, 1, 1], port: 3478, marker: 72))
    try await udpEventually("another failed negotiation") { await script.calls >= 4 }
    let initialOpens = await relays.opened()
    try udpRequire(controller.capabilities == nil && initialOpens.isEmpty,
                   "no timeout grace or UDP admission before authenticated capabilities")
    print("capability authentication, protocol failure and initial timeout remain fail closed: passed")
}

private func runCapabilityRetentionCheck(associationSupported: Bool) async throws {
    let script = ControllerCapabilityScript()
    let source = ControllerUDPPackets(), relays = ControllerUDPRelays(associationSupported: associationSupported, capabilityScript: script)
    let controller = TunnelController(packetSource: source, secret: controllerUDPSecret,
        transportFactory: { relays.make() }, capabilityPollInterval: .milliseconds(20))
    defer { controller.stop() }
    try udpRequire(controller.start(), "capability retention controller starts")
    try await primeControllerUDP(controller, source, relays, previousOpens: 0, marker: 61)
    let original = await relays.opened()[0].0
    let prior = await script.calls
    let threeTimeouts: [Result<UInt8, DroidBridgeError>] = Array(repeating: .failure(.relayTimedOut), count: 3)
    await script.set(threeTimeouts + [.success(1)] + threeTimeouts + [.success(1)])
    // Observing the next query guarantees the preceding query and controller action completed.
    try await udpEventually("two timeout bursts and intervening recovery processed") { await script.calls >= prior + 9 }
    try udpRequire(!(await original.state.cancelRequested), "three timeouts must retain UDP; a successful query resets the budget")
    source.submit(controllerUDPPacket(sourcePort: 6000, peer: [1, 1, 1, 1], port: 3478, marker: 62))
    try await udpEventually("same association sends after capability timeout") { await original.state.packets.contains { $0.last == 62 } }
    let peer = try UDPAssociationPeer(address: Data([1, 1, 1, 1]), port: 3478)
    let reply = try associationSupported
        ? UDPAssociationFrame(peer: peer, payload: Data([63]), inbound: true, sequence: 0).encoded()
        : DatagramFrame(payload: Data([63]), inbound: true, sequence: 0).encoded()
    await original.inject(reply)
    try await udpEventually("same association receives after capability timeout") { source.written.contains { $0.last == 63 } }
    await script.set([.failure(.relayTimedOut), .success(2)], then: .success(2))
    try await udpEventually("real generation change after a timeout retires old UDP") {
        await original.state.cancelRequested && controller.capabilities?.cellularGeneration == 2
    }
    try await primeControllerUDP(controller, source, relays, previousOpens: 1, marker: 64)
    let replacement = await relays.opened()[1].0
    await script.set(Array(repeating: .failure(.relayTimedOut), count: 4), then: .success(2))
    try await udpEventually("four consecutive timeouts retire replacement UDP") {
        await replacement.state.cancelRequested
    }
    print("capability bounded retention, bidirectional UDP, recovery and generation change (association=\(associationSupported)): passed")
}
