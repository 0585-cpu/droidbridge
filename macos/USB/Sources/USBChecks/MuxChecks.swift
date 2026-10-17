import Foundation
import Darwin
import DroidBridgeUSB

final class TestUSBWire: AoaByteTransport, @unchecked Sendable {
    private let condition = NSCondition()
    private var incoming: [Data] = []
    private var outgoing: [Data] = []
    private var closed = false
    private var writes = 0
    var isClosed: Bool { condition.lock(); defer { condition.unlock() }; return closed }
    var writeCount: Int { condition.lock(); defer { condition.unlock() }; return writes }
    func readChunk() throws -> Data? {
        condition.lock(); defer { condition.unlock() }
        while incoming.isEmpty && !closed { condition.wait() }
        return incoming.isEmpty ? nil : incoming.removeFirst()
    }
    func write(_ data: Data) throws {
        condition.lock(); defer { condition.unlock() }
        if closed { throw AoaError.usb("closed") }
        writes += 1
        // One write may carry several frames (the mux packs its queue), like the real wire.
        var decoder = AoaFrameDecoder()
        for frame in try decoder.append(data) {
            if frame.type == .ping { incoming.append(try AoaFrame(type: .pong, streamID: 0).encoded()) }
            else { outgoing.append(try frame.encoded()) }
        }
        condition.broadcast()
    }
    func close() { condition.lock(); closed = true; condition.broadcast(); condition.unlock() }
    func feed(_ frame: AoaFrame) {
        condition.lock(); incoming.append(frame.encoded()); condition.broadcast(); condition.unlock()
    }
    func next(timeout: TimeInterval = 5) throws -> AoaFrame {
        condition.lock(); defer { condition.unlock() }
        let limit = Date().addingTimeInterval(timeout)
        while outgoing.isEmpty && !closed {
            guard condition.wait(until: limit) else { throw AoaError.usb("test timed out") }
        }
        guard !outgoing.isEmpty else { throw AoaError.usb("test wire closed") }
        var decoder = AoaFrameDecoder()
        return try decoder.append(outgoing.removeFirst())[0]
    }
}

func connectLocal(_ port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { Darwin.close(fd); throw AoaError.usb("test connect") }
    return fd
}

func runMuxChecks() throws {
    try runLostWindowCheck()
    try runStartupCancellationCheck()
    let wire = TestUSBWire()
    let mux = AoaMultiplexer(transport: wire)
    Thread.detachNewThread {
        do {
            let reset = try wire.next()
            precondition(reset.type == .reset && reset.streamID == 0 && reset.payload.count == 16)
            wire.feed(try AoaFrame(type: .resetOK, streamID: 0, payload: reset.payload))
        } catch { fatalError("reset failed: \(error)") }
    }
    let ports = try mux.start(relayPort: 0, pairingPort: 0)
    defer { mux.stop() }
    let client = try connectLocal(ports.relay)
    defer { Darwin.close(client) }
    let opened = try wire.next()
    check(opened.type == .open && opened.service == .relay, "relay service allowlist")
    wire.feed(try AoaFrame(type: .openOK, streamID: opened.streamID))
    let request: [UInt8] = [1,2,3,4]
    _ = request.withUnsafeBytes { Darwin.send(client, $0.baseAddress!, $0.count, 0) }
    let sent = try wire.next()
    check(sent.type == .data && sent.payload == Data(request), "socket payload crosses mux")
    wire.feed(try AoaFrame(type: .data, streamID: opened.streamID, payload: Data([9,8,7])))
    var reply = [UInt8](repeating: 0, count: 3)
    let count = Darwin.recv(client, &reply, 3, MSG_WAITALL)
    check(count == 3 && reply == [9,8,7], "remote payload reaches real socket")
    let credit = try wire.next()
    check(credit.type == .window && AoaFrame.consumedCount(credit.payload) == 3, "credit follows consumed data")
    _ = Darwin.shutdown(client, SHUT_WR)
    let fin = try wire.next()
    check(fin.type == .fin, "local half-close preserved")
    wire.feed(try AoaFrame(type: .fin, streamID: opened.streamID))
    check(Darwin.recv(client, &reply, 1, 0) == 0, "remote half-close delivered")

    let paired = try connectLocal(ports.pairing)
    defer { Darwin.close(paired) }
    var next = try wire.next()
    if next.type == .close { next = try wire.next() }
    check(next.type == .open && next.service == .pairing, "pairing uses separate stream")
    wire.feed(try AoaFrame(type: .openOK, streamID: next.streamID))
    wire.feed(try AoaFrame(type: .window, streamID: next.streamID, payload: AoaFrame.consumedBytes(1)))
    check(Darwin.recv(paired, &reply, 1, 0) == 0, "credit inflation closes transport")
    print("AOA real-loopback multiplex checks passed")
    try runBulkChecks()
    try runOccupiedPortCheck()
}

private func runLostWindowCheck() throws {
    let wire = TestUSBWire()
    let mux = AoaMultiplexer(transport: wire)
    Thread.detachNewThread {
        do {
            let reset = try wire.next()
            wire.feed(try AoaFrame(type: .resetOK, streamID: 0, payload: reset.payload))
        } catch { fatalError("reset failed: \(error)") }
    }
    let ports = try mux.start(relayPort: 0, pairingPort: 0)
    defer { mux.stop() }
    let client = try connectLocal(ports.relay)
    defer { Darwin.close(client) }
    let opened = try wire.next()
    wire.feed(try AoaFrame(type: .openOK, streamID: opened.streamID))
    let payload = Data(repeating: 7, count: 16384)
    wire.feed(try AoaFrame(type: .data, streamID: opened.streamID, payload: payload))
    var received = [UInt8](repeating: 0, count: payload.count)
    check(Darwin.recv(client, &received, received.count, MSG_WAITALL) == payload.count, "window recovery payload")
    let lost = try wire.next(timeout:0.5) // Sparse credit must not wait for the 2s refresh.
    let repeated = try wire.next()
    check(repeated.type == .window && repeated.payload == lost.payload, "lost window is repeated without new data")
    check(mux.isConnected, "window recovery retains the USB session")
    print("AOA lost-window recovery check passed")
}

private func runStartupCancellationCheck() throws {
    let wire = TestUSBWire()
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    let mux = AoaMultiplexer(transportFactory: {
        entered.signal()
        release.wait()
        return wire
    })
    Thread.detachNewThread {
        do { _ = try mux.start(relayPort: 0, pairingPort: 0); fatalError("cancelled start succeeded") }
        catch { finished.signal() }
    }
    check(entered.wait(timeout: .now() + 3) == .success, "transport open started")
    mux.stop()
    release.signal()
    check(finished.wait(timeout: .now() + 3) == .success, "Stop unblocks pending handshake")
    check(wire.isClosed, "USB opened after Stop must be closed, not leaked")
    print("AOA Stop-during-open resource cleanup check passed")
}

private func runBulkChecks() throws {
    let wire = TestUSBWire()
    let mux = AoaMultiplexer(transport: wire)
    Thread.detachNewThread {
        do {
            let reset = try wire.next()
            wire.feed(try AoaFrame(type: .resetOK, streamID: 0, payload: reset.payload))
        } catch { fatalError("reset failed: \(error)") }
    }
    let ports = try mux.start(relayPort: 0, pairingPort: 0)
    defer { mux.stop() }
    let client = try connectLocal(ports.relay)
    defer { Darwin.close(client) }
    let opened = try wire.next()
    wire.feed(try AoaFrame(type: .openOK, streamID: opened.streamID))
    let payload = Data((0..<262_144).map { UInt8(truncatingIfNeeded: $0 * 31) })
    Thread.detachNewThread {
        payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                precondition(sent > 0)
                offset += sent
            }
        }
        _ = Darwin.shutdown(client, SHUT_WR)
    }
    var uploaded = Data()
    while uploaded.count < payload.count {
        let frame = try wire.next()
        check(frame.type == .data, "bulk upload is DATA")
        uploaded.append(frame.payload)
        if uploaded.count % AoaFrame.initialCredit == 0 {
            if uploaded.count < payload.count {
                do {
                    _ = try wire.next(timeout: 0.3)
                    fatalError("FAIL: sender exceeded its window before the next cumulative ACK")
                } catch AoaError.usb(let message) {
                    check(message == "test timed out", "credit wait must not close transport")
                }
            }
            // Drop every intermediate update. A cumulative refresh restores the whole window.
            wire.feed(try AoaFrame(type: .window, streamID: opened.streamID, payload: AoaFrame.consumedBytes(UInt64(uploaded.count))))
            // Repeating or delaying a refresh must never inflate credit or kill the session.
            wire.feed(try AoaFrame(type: .window, streamID: opened.streamID, payload: AoaFrame.consumedBytes(UInt64(uploaded.count))))
            wire.feed(try AoaFrame(type: .window, streamID: opened.streamID, payload: AoaFrame.consumedBytes(0)))
        }
    }
    check(uploaded == payload, "bulk upload preserves bytes across receive windows")
    let uploadFIN = try wire.next()
    check(uploadFIN.type == .fin, "bulk upload half-close")

    // Sending four windows of replies after local EOF must still deliver every byte.
    let received = LockedBytes()
    let drained = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            if count <= 0 { break }
            received.append(Data(buffer.prefix(count)))
        }
        drained.signal()
    }
    for offset in stride(from: 0, to: payload.count, by: AoaFrame.maximumPayload) {
        let chunk = payload.subdata(in: offset..<(offset + AoaFrame.maximumPayload))
        wire.feed(try AoaFrame(type: .data, streamID: opened.streamID, payload: chunk))
        let credit = try wire.next()
        check(credit.type == .window && AoaFrame.consumedCount(credit.payload) == UInt64(offset + chunk.count), "bulk reply returns consumed credit")
    }
    wire.feed(try AoaFrame(type: .fin, streamID: opened.streamID))
    check(drained.wait(timeout: .now() + 5) == .success, "bulk reply reaches EOF")
    check(received.value == payload, "bulk reply is not truncated by half-close")
    print("AOA 256-KiB bidirectional/half-close checks passed")
}

private final class LockedBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); bytes.append(data); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

private func runOccupiedPortCheck() throws {
    let occupied = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    defer { Darwin.close(occupied) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(occupied, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    check(bound == 0 && Darwin.listen(occupied, 1) == 0, "occupy test loopback port")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(occupied, $0, &length) }
    }
    let attempted = LockedBytes()
    let mux = AoaMultiplexer(transportFactory: {
        attempted.append(Data([1]))
        throw AoaError.usb("USB must not be opened")
    })
    do {
        _ = try mux.start(relayPort: UInt16(bigEndian: address.sin_port), pairingPort: 0)
        fatalError("occupied port unexpectedly succeeded")
    } catch {}
    check(attempted.value.isEmpty, "port conflict fails before USB mode switch")
    print("AOA occupied-port isolation check passed")
}
