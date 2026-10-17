import Foundation
import Darwin
import DroidBridgeUSB

/// A stalled USB writer with a working reader, matching the observed phone slowdown.
private final class GatedUSBWire: AoaByteTransport, @unchecked Sendable {
    let wire = TestUSBWire()
    private let gate = NSCondition()
    private var paused = false
    private var closed = false
    let blocked = DispatchSemaphore(value: 0)
    let blockedWriteExited = DispatchSemaphore(value: 0)
    func pause() { gate.lock(); paused = true; gate.unlock() }
    func resume() { gate.lock(); paused = false; gate.broadcast(); gate.unlock() }
    func readChunk() throws -> Data? { try wire.readChunk() }
    func write(_ data: Data) throws {
        gate.lock()
        let didBlock = paused
        if didBlock { blocked.signal() }
        while paused && !closed { gate.wait() }
        let wasClosed = closed
        gate.unlock()
        defer { if didBlock { blockedWriteExited.signal() } }
        if wasClosed { throw AoaError.usb("closed") }
        try wire.write(data)
    }
    func close() {
        gate.lock(); closed = true; gate.broadcast(); gate.unlock()
        wire.close()
    }
}

private func startGatedMux(_ wire: GatedUSBWire) throws -> (AoaMultiplexer, AoaMultiplexer.Ports) {
    let mux = AoaMultiplexer(transport: wire)
    Thread.detachNewThread {
        do {
            let reset = try wire.wire.next()
            wire.wire.feed(try AoaFrame(type: .resetOK, streamID: 0, payload: reset.payload))
        } catch { fatalError("backpressure reset: \(error)") }
    }
    return (mux, try mux.start(relayPort: 0, pairingPort: 0))
}

func runBackpressureChecks() throws {
    if !CommandLine.arguments.contains("--upload-only") { try runWindowBacklogCheck() }
    try runUploadBacklogCheck()
    try runUploadBacklogCheck(retirement: .stop)
    try runUploadBacklogCheck(retirement: .peerClose)
}

// Break caught: queuing one WINDOW per consumed chunk kills every stream when
// USB writes stall, although cumulative credit can safely replace older credit.
private func runWindowBacklogCheck() throws {
    let wire = GatedUSBWire()
    let (mux, ports) = try startGatedMux(wire)
    defer { mux.stop() }
    let client = try connectLocal(ports.relay)
    defer { Darwin.close(client) }
    let opened = try wire.wire.next()
    wire.wire.feed(try AoaFrame(type: .openOK, streamID: opened.streamID))
    wire.pause()
    var byte: UInt8 = 0
    // Stay inside the peer's existing window; no credit from the blocked writer
    // is needed to deliver these 2,048 valid chunks.
    for index in 0..<2048 {
        wire.wire.feed(try AoaFrame(type: .data, streamID: opened.streamID,
                                   payload: Data([UInt8(truncatingIfNeeded: index)])))
        check(Darwin.recv(client, &byte, 1, MSG_WAITALL) == 1,
              "stalled USB acknowledgements must not disconnect a valid download")
        check(byte == UInt8(truncatingIfNeeded: index), "backlog preserves download bytes")
    }
    check(wire.blocked.wait(timeout: .now() + 2) == .success, "WINDOW writer was stalled")
    check(mux.isConnected, "cumulative WINDOW backlog preserves USB session")
    wire.resume()
    var windows = 0
    var consumed: UInt64 = 0
    while consumed < 2048 {
        let frame = try wire.wire.next()
        check(frame.type == .window, "resume produces cumulative credit")
        let next = AoaFrame.consumedCount(frame.payload)
        check(next >= consumed && next <= 2048, "coalescing cannot inflate/regress credit")
        consumed = next; windows += 1
    }
    check(windows <= 3, "stalled consumption is coalesced instead of replaying obsolete credit")
    print("AOA stalled writer: 2,048 WINDOW updates coalesced; connection retained")
}

// Break caught: many producers can enqueue DATA/FIN faster than USB drains;
// the mux must pause reads, then resume all streams without byte/EOF loss.
private enum PausedRetirement { case none, stop, peerClose }

private func runUploadBacklogCheck(retirement: PausedRetirement = .none) throws {
    let wire = GatedUSBWire()
    let (mux, ports) = try startGatedMux(wire)
    defer { mux.stop() }
    var clients: [Int32] = []
    defer { clients.forEach { Darwin.close($0) } }
    var ids: [UInt32] = []
    for _ in 0..<240 {
        let client = try connectLocal(ports.relay)
        clients.append(client)
        let opened = try wire.wire.next()
        check(opened.type == .open, "stress stream opens before congestion")
        ids.append(opened.streamID)
        wire.wire.feed(try AoaFrame(type: .openOK, streamID: opened.streamID))
    }
    wire.pause()
    // Leave credit for the EOF receive; a full initial window would pause at
    // exactly 64 KiB even without global writer backpressure.
    let payload = Data((0..<65_408).map { UInt8(truncatingIfNeeded: $0 * 31) })
    for client in clients {
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard sent > 0 else { throw AoaError.usb("upload producer closed") }
                offset += sent
            }
        }
        _ = Darwin.shutdown(client, SHUT_WR)
    }
    check(wire.blocked.wait(timeout: .now() + 2) == .success, "DATA writer was stalled")
    // Give the real Network.framework callbacks a bounded opportunity to fill
    // the old 1,024-frame queue before releasing the USB writer.
    Thread.sleep(forTimeInterval: 0.5)
    check(mux.isConnected, "240 stalled uploads must not overflow the USB writer")
    if retirement == .stop {
        mux.stop()
        check(wire.blockedWriteExited.wait(timeout: .now() + 2) == .success,
              "Stop wakes a USB write with local DATA/FIN still pending")
        check(!mux.isConnected && wire.wire.isClosed, "Stop retires the congested session")
        var byte: UInt8 = 0
        check(Darwin.recv(clients.last!, &byte, 1, 0) <= 0, "Stop cancels a paused local socket")
        print("AOA Stop before backlog drain: pending DATA/FIN retired; writer woke")
        return
    }
    let retired: Set<UInt32> = retirement == .peerClose ? Set(ids.suffix(120)) : []
    if !retired.isEmpty {
        for id in retired { wire.wire.feed(try AoaFrame(type: .close, streamID: id)) }
        // This reply is an observable reader barrier after every peer CLOSE.
        wire.wire.feed(try AoaFrame(type: .data, streamID: ids[0], payload: Data([73])))
        var byte: UInt8 = 0
        check(Darwin.recv(clients[0], &byte, 1, 0) == 1 && byte == 73, "peer CLOSE batch handled while writer stalls")
        check(Darwin.recv(clients.last!, &byte, 1, 0) <= 0, "peer CLOSE cancels a paused local socket")
    }
    let writesBeforeDrain = wire.wire.writeCount
    wire.resume()
    var received: [UInt32: Data] = [:]
    var finished: Set<UInt32> = []
    var drainedFrames = 0
    while finished.count < ids.count - retired.count {
        let frame = try wire.wire.next()
        drainedFrames += 1
        // Already queued frames of a retired ID may reach the peer, which ignores
        // them by protocol. Retired streams must not block surviving producers.
        if retired.contains(frame.streamID) { continue }
        switch frame.type {
        case .data:
            check(!finished.contains(frame.streamID), "DATA must precede FIN")
            received[frame.streamID, default: Data()].append(frame.payload)
            wire.wire.feed(try AoaFrame(type: .window, streamID: frame.streamID,
                payload: AoaFrame.consumedBytes(UInt64(received[frame.streamID]!.count))))
        case .fin:
            check(received[frame.streamID] == payload, "all paused streams resume with intact bytes")
            check(finished.insert(frame.streamID).inserted, "one FIN per stream")
        case .window:
            check(!retired.isEmpty && frame.streamID == ids[0] && AoaFrame.consumedCount(frame.payload) == 1,
                  "peer CLOSE reader barrier returns only its consumed credit")
        default: fatalError("unexpected frame during upload recovery: \(frame.type)")
        }
    }
    check(mux.isConnected, "draining a backlog retains the original session")
    check(wire.wire.writeCount - writesBeforeDrain < drainedFrames, "a drained backlog packs small frames into shared bulk writes")
    if !retired.isEmpty {
        print("AOA peer CLOSE while paused: 120 retired, 120 survivors drained with intact bytes/FIN")
        return
    }
    // Stop must also wake the writer, even when it has no progress.
    wire.pause()
    wire.wire.feed(try AoaFrame(type: .data, streamID: ids[0], payload: Data([1])))
    var byte: UInt8 = 0
    check(Darwin.recv(clients[0], &byte, 1, 0) == 1, "stream remains bidirectional after FIN")
    check(wire.blocked.wait(timeout: .now() + 2) == .success, "second writer stall reached")
    mux.stop()
    check(!mux.isConnected && wire.wire.isClosed, "Stop closes stalled writer and all streams")
    print("AOA 240-stream stalled upload: all bytes/FIN restored; Stop unblocks writer")
}
