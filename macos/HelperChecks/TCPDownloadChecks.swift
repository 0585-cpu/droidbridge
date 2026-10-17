import DroidBridgeShared
import Foundation

private let downloadSecret = Data(repeating: 37, count: 32)
private struct DownloadCheckError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func downloadRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw DownloadCheckError(message: message) }
}
private func downloadEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw DownloadCheckError(message: "download condition timed out")
}

/// Only the external Android transport is substituted; controller, relay reader and C/lwIP are real.
private actor DownloadWire: RelayTransport {
    private var inbox = Data()
    private var opened = false
    private var cancelled = false
    private(set) var delivered = 0
    var isOpen: Bool { opened }
    var isCancelled: Bool { cancelled }
    func finishSending() async throws {}
    func start() async throws {}
    func cancel() async { cancelled = true }
    func send(_ data: Data) async throws {
        let (h, mac) = try DbpCodec.decodeHeader(data)
        let payload = Data(data.dropFirst(64))
        guard DbpCodec.verifyHMAC(secret: downloadSecret, header: h, payload: payload, hmac: mac) else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        let kind: DbpMessageType, response: Data
        switch h.type {
        case .hello: kind = .helloOk; response = Data()
        case .openTcp: kind = .openOk; response = Data(); opened = true
        case .capabilities:
            kind = .capabilitiesResponse
            var caps = Data(count: 61)
            caps[1] = 59; caps[2] = 1; caps[10] = 1; caps[18] = 1; caps[19] = 64; caps[20] = 64
            response = caps
        default: throw DownloadCheckError(message: "unexpected download control message")
        }
        inbox.append(DbpCodec.frame(secret: downloadSecret,
            header: DbpHeader(type: kind, clientNonce: h.clientNonce, serverNonce: 73, unixTime: h.unixTime),
            payload: response))
    }
    func receiveExactly(_ count: Int) async throws -> Data {
        guard !cancelled, inbox.count >= count else { throw CancellationError() }
        let bytes = Data(inbox.prefix(count)); inbox.removeFirst(count); return bytes
    }
    func receive(maxLength: Int) async throws -> Data {
        guard !cancelled else { throw CancellationError() }
        let count = min(maxLength, 1024 * 1024 - delivered)
        let bytes = Data((delivered..<(delivered + count)).map { UInt8(truncatingIfNeeded: $0 / 251) })
        delivered += count
        return bytes
    }
}
private final class DownloadWires: @unchecked Sendable {
    private let lock = NSLock()
    private var wires: [DownloadWire] = []
    func make() -> any RelayTransport {
        let wire = DownloadWire(); lock.withLock { wires.append(wire) }; return wire
    }
    func stream() async -> DownloadWire? {
        let all = lock.withLock { wires }
        for wire in all { if await wire.isOpen { return wire } }
        return nil
    }
}
private final class DownloadPackets: PacketSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reader: (@Sendable ([Data]) -> Void)?
    private var output: [Data] = []
    func read(_ handler: @escaping @Sendable ([Data]) -> Void) { lock.withLock { reader = handler } }
    func write(_ packets: [Data]) { lock.withLock { output.append(contentsOf: packets) } }
    func submit(_ packet: Data) {
        let handler = lock.withLock { let h = reader; reader = nil; return h }; handler?([packet])
    }
    func take() -> [Data] { lock.withLock { let result = output; output.removeAll(); return result } }
    var hasOutput: Bool { lock.withLock { !output.isEmpty } }
}
private func downloadU32(_ data: Data, _ offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
}
private func downloadChecksum(_ bytes: [UInt8]) -> UInt16 {
    var sum: UInt32 = 0
    for i in stride(from: 0, to: bytes.count, by: 2) {
        sum += UInt32(bytes[i]) << 8
        if i + 1 < bytes.count { sum += UInt32(bytes[i + 1]) }
    }
    while sum >> 16 != 0 { sum = (sum & 65535) + (sum >> 16) }
    return ~UInt16(sum)
}
private func downloadPacket(_ flags: UInt8, ack: UInt32) -> Data {
    var p: [UInt8] = [0x45,0,0,40,0,1,0,0,64,6,0,0,198,18,0,2,93,184,216,34,
                      0x9c,0x40,1,0xbb,0,0,3,flags == 2 ? 0xe8 : 0xe9,0,0,0,0,0x50,flags,0xff,0xff,0,0,0,0]
    for i in 0..<4 { p[28 + i] = UInt8(truncatingIfNeeded: ack >> (24 - i * 8)) }
    let ip = downloadChecksum(Array(p.prefix(20)))
    p[10] = UInt8(ip >> 8); p[11] = UInt8(ip & 255)
    let tcp = downloadChecksum(Array(p[12..<20]) + [0,6,0,20] + Array(p[20...]))
    p[36] = UInt8(tcp >> 8); p[37] = UInt8(tcp & 255)
    return Data(p)
}

private func runTCPDownloadCompletionCheck() async throws {
    let packets = DownloadPackets(), wires = DownloadWires()
    let controller = TunnelController(packetSource: packets, secret: downloadSecret, transportFactory: { wires.make() })
    defer { controller.stop() }
    try downloadRequire(controller.start(), "download controller starts")
    packets.submit(downloadPacket(2, ack: 0))
    try await downloadEventually { packets.hasOutput }
    let syn = packets.take().first { $0[33] & 0x12 == 0x12 }!
    var ack = downloadU32(syn, 24) &+ 1
    packets.submit(downloadPacket(0x10, ack: ack))
    try await downloadEventually { await wires.stream() != nil }
    let wire = await wires.stream()!
    try await downloadEventually { await wire.delivered >= 262144 }
    // Hold ACKs well beyond the reader's scheduling turn: it must stop, retaining one chunk.
    try await Task.sleep(for: .milliseconds(150))
    let readAhead = await wire.delivered
    try downloadRequire(readAhead <= 327680, "reader ran ahead of the bounded engine queue: \(readAhead)")
    var received = Data(), fin = false
    let deadline = ContinuousClock.now + .seconds(12)
    while !fin && ContinuousClock.now < deadline {
        let batch = packets.take()
        for packet in batch {
            try downloadRequire(packet[33] & 4 == 0, "download reset under receiver pressure")
            let offset = 20 + Int(packet[32] >> 4) * 4
            if packet.count > offset {
                try downloadRequire(downloadU32(packet, 24) == ack, "download duplicated or skipped bytes")
                let data = packet.dropFirst(offset)
                received.append(contentsOf: data)
                ack &+= UInt32(data.count)
            }
            if packet[33] & 1 != 0 { fin = true }
        }
        if !batch.isEmpty {
            packets.submit(downloadPacket(fin ? 0x11 : 0x10, ack: fin ? ack &+ 1 : ack))
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    try downloadRequire(received.count == 1048576 && fin, "download tail or EOF lost: \(received.count)")
    let expected = Data((0..<1048576).map { UInt8(truncatingIfNeeded: $0 / 251) })
    try downloadRequire(received == expected, "download bytes differ after pressure and resume")
    print("TCP download pressure, exact-byte resume and EOF: passed")
}

private func runTCPDownloadStopCheck() async throws {
    let packets = DownloadPackets(), wires = DownloadWires()
    let controller = TunnelController(packetSource: packets, secret: downloadSecret, transportFactory: { wires.make() })
    defer { controller.stop() }
    try downloadRequire(controller.start(), "pressure-stop controller starts")
    packets.submit(downloadPacket(2, ack: 0))
    try await downloadEventually { packets.hasOutput }
    let syn = packets.take().first { $0[33] & 0x12 == 0x12 }!
    packets.submit(downloadPacket(0x10, ack: downloadU32(syn, 24) &+ 1))
    try await downloadEventually { await wires.stream() != nil }
    let wire = await wires.stream()!
    try await downloadEventually { await wire.delivered >= 327680 }
    controller.stop()
    try await downloadEventually { await wire.isCancelled }
    _ = packets.take()
    try await Task.sleep(for: .milliseconds(50))
    try downloadRequire(!packets.hasOutput, "stopped download emits late packets")
    let count = await wire.delivered
    try downloadRequire(count == 327680, "stopped reader continued consuming remote bytes")
    print("TCP download Stop while pressured: passed")
}

func runTCPDownloadChecks() async throws {
    try await runTCPDownloadCompletionCheck()
    try await runTCPDownloadStopCheck()
}

/// Only the remote relay is simulated. Real controller + C/lwIP must preserve FIN ordering.
private actor HalfCloseWire: RelayTransport {
    private var inbox = Data()
    private(set) var isOpen = false
    private(set) var cancelled = false
    private(set) var writePending = false
    private(set) var request = Data()
    private(set) var finishes = 0
    private var writesReleased = false
    private var replied = false
    private var forcedEOF = false
    func endReceive() { forcedEOF = true }
    func start() async throws {}
    func cancel() async { cancelled = true }
    func releaseWrites() { writesReleased = true }
    func finishSending() async throws {
        guard !cancelled else { throw CancellationError() }
        finishes += 1
    }
    func send(_ data: Data) async throws {
        guard !cancelled else { throw CancellationError() }
        if isOpen {
            writePending = true
            while !writesReleased && !cancelled { try await Task.sleep(for: .milliseconds(2)) }
            guard !cancelled else { throw CancellationError() }
            request.append(data)
            return
        }
        let (h, mac) = try DbpCodec.decodeHeader(data)
        let payload = Data(data.dropFirst(64))
        guard DbpCodec.verifyHMAC(secret: downloadSecret, header: h, payload: payload, hmac: mac) else {
            throw DroidBridgeError.relayAuthenticationFailed
        }
        let kind: DbpMessageType, response: Data
        switch h.type {
        case .hello: kind = .helloOk; response = Data()
        case .openTcp: kind = .openOk; response = Data(); isOpen = true
        case .capabilities:
            kind = .capabilitiesResponse
            var caps = Data(count: 61)
            caps[1] = 59; caps[2] = 1; caps[10] = 1; caps[18] = 1; caps[19] = 64; caps[20] = 64
            response = caps
        default: throw DownloadCheckError(message: "unexpected half-close control message")
        }
        inbox.append(DbpCodec.frame(secret: downloadSecret,
            header: DbpHeader(type: kind, clientNonce: h.clientNonce, serverNonce: 73, unixTime: h.unixTime),
            payload: response))
    }
    func receiveExactly(_ count: Int) async throws -> Data {
        guard !cancelled, inbox.count >= count else { throw CancellationError() }
        let data = Data(inbox.prefix(count)); inbox.removeFirst(count); return data
    }
    func receive(maxLength: Int) async throws -> Data {
        while finishes == 0 && !forcedEOF && !cancelled { try await Task.sleep(for: .milliseconds(2)) }
        guard !cancelled else { throw CancellationError() }
        if replied || forcedEOF { return Data() }
        replied = true
        return Data("response-after-request-EOF".utf8)
    }
}

private final class HalfCloseWires: @unchecked Sendable {
    private let lock = NSLock()
    private var wires: [HalfCloseWire] = []
    func make() -> any RelayTransport {
        let wire = HalfCloseWire(); lock.withLock { wires.append(wire) }; return wire
    }
    func stream(_ index: Int) async -> HalfCloseWire? {
        let all = lock.withLock { wires }
        var streams: [HalfCloseWire] = []
        for wire in all { if await wire.isOpen { streams.append(wire) } }
        return streams.count > index ? streams[index] : nil
    }
}

private func halfClosePacket(port: UInt16, seq: UInt32, ack: UInt32, flags: UInt8, data: Data = Data()) -> Data {
    var p = [UInt8](downloadPacket(flags, ack: ack)) + data
    p[2] = UInt8(p.count >> 8); p[3] = UInt8(truncatingIfNeeded: p.count)
    p[20] = UInt8(port >> 8); p[21] = UInt8(truncatingIfNeeded: port)
    for i in 0..<4 { p[24+i] = UInt8(truncatingIfNeeded: seq >> (24-i*8)) }
    p[10] = 0; p[11] = 0; p[36] = 0; p[37] = 0
    let ip = downloadChecksum(Array(p.prefix(20)))
    p[10] = UInt8(ip >> 8); p[11] = UInt8(truncatingIfNeeded: ip)
    let length = p.count - 20
    let tcp = downloadChecksum(Array(p[12..<20]) + [0,6,UInt8(length >> 8),UInt8(truncatingIfNeeded: length)] + Array(p[20...]))
    p[36] = UInt8(tcp >> 8); p[37] = UInt8(truncatingIfNeeded: tcp)
    return Data(p)
}

func runTCPHalfCloseChecks() async throws {
    let packets = DownloadPackets(), wires = HalfCloseWires()
    let controller = TunnelController(packetSource: packets, secret: downloadSecret,
        maximumFlows: 1, transportFactory: { wires.make() })
    defer { controller.stop() }
    try downloadRequire(controller.start(), "half-close controller starts")
    // More sequential connections than the available slot count must complete without leaking slots.
    for cycle in 0..<3 {
        let port = UInt16(40120 + cycle)
        var seq: UInt32 = 1000
        packets.submit(halfClosePacket(port: port, seq: seq, ack: 0, flags: 2))
        try await downloadEventually { packets.hasOutput }
        guard let syn = packets.take().first(where: { $0[33] & 0x12 == 0x12 }) else {
            throw DownloadCheckError(message: "flow slot not reusable after half-close")
        }
        var ack = downloadU32(syn, 24) &+ 1; seq += 1
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x10))
        try await downloadEventually { await wires.stream(cycle) != nil }
        let wire = await wires.stream(cycle)!
        let first = Data("request-".utf8), tail = Data("tail".utf8)
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x18, data: first))
        seq += UInt32(first.count)
        try await downloadEventually { await wire.writePending }
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x18, data: tail))
        seq += UInt32(tail.count)
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x11)); seq += 1
        await wire.releaseWrites()
        var received = Data(), fin = false
        let deadline = ContinuousClock.now + .seconds(3)
        while !fin && ContinuousClock.now < deadline {
            let batch = packets.take()
            for packet in batch {
                try downloadRequire(packet[33] & 4 == 0, "client FIN reset the response")
                let offset = 20 + Int(packet[32] >> 4) * 4
                if packet.count > offset {
                    try downloadRequire(downloadU32(packet, 24) == ack, "half-close response reordered")
                    received.append(packet.dropFirst(offset)); ack += UInt32(packet.count-offset)
                }
                if packet[33] & 1 != 0 { fin = true }
            }
            if !batch.isEmpty {
                packets.submit(halfClosePacket(port: port, seq: seq, ack: fin ? ack+1 : ack, flags: 0x10))
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try downloadRequire(received == Data("response-after-request-EOF".utf8) && fin,
            "client FIN discarded the delayed response")
        let request = await wire.request, finishes = await wire.finishes
        try downloadRequire(request == Data("request-tail".utf8) && finishes == 1,
            "FIN must follow every queued request byte exactly once")
        try await downloadEventually { controller.activeFlowCount == 0 }
        try await downloadEventually { await wire.cancelled }
    }
    // Even when the client's PCB closes, the Swift FIFO may still hold upload bytes.
    for cycle in 3..<5 {
        let clientFirst = cycle == 3
        let port = UInt16(40120 + cycle)
        var seq: UInt32 = 1000
        packets.submit(halfClosePacket(port: port, seq: seq, ack: 0, flags: 2))
        try await downloadEventually { packets.hasOutput }
        guard let syn = packets.take().first(where: { $0[33] & 0x12 == 0x12 }) else {
            throw DownloadCheckError(message: "missing SYN ACK for early remote EOF")
        }
        var ack = downloadU32(syn, 24) &+ 1; seq += 1
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x10))
        try await downloadEventually { await wires.stream(cycle) != nil }
        let wire = await wires.stream(cycle)!
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x18, data: Data("request-".utf8)))
        seq += 8
        try await downloadEventually { await wire.writePending }
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x18, data: Data("tail".utf8)))
        seq += 4
        if clientFirst {
            packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x11)); seq += 1
        }
        await wire.endReceive()
        var fin = false
        let deadline = ContinuousClock.now + .seconds(3)
        while !fin && ContinuousClock.now < deadline {
            for packet in packets.take() {
                try downloadRequire(packet[33] & 4 == 0, "early remote EOF reset client")
                if packet[33] & 1 != 0 { fin = true }
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        try downloadRequire(fin, "early remote EOF did not reach client")
        ack += 1
        packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x10))
        if !clientFirst { packets.submit(halfClosePacket(port: port, seq: seq, ack: ack, flags: 0x11)) }
        try await downloadEventually { controller.activeFlowCount == 0 }
        let prematurelyCancelled = await wire.cancelled
        try downloadRequire(!prematurelyCancelled, "PCB completion discarded queued upload")
        await wire.releaseWrites()
        try await downloadEventually { await wire.cancelled }
        let request = await wire.request, finishes = await wire.finishes
        try downloadRequire(request == Data("request-tail".utf8) && finishes == 1,
            "early remote EOF lost queued upload or its FIN")
    }
    print("TCP client FIN: delayed response, queued request tail, and repeated slot reuse passed")
}
