import Foundation
import Darwin
import DroidBridgeUSB

private final class FailingWriteWire: AoaByteTransport, @unchecked Sendable {
    let wire = TestUSBWire()
    let writing = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let wroteAfterFailure = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var failed = false

    func readChunk() throws -> Data? { try wire.readChunk() }
    func close() { wire.close() }
    func write(_ data: Data) throws {
        if lock.withLock({ failed }) {
            wroteAfterFailure.signal()
            throw AoaError.usb("write attempted after failed frame")
        }
        var decoder = AoaFrameDecoder()
        let frame = try decoder.append(data)[0]
        if frame.type == .data {
            writing.signal()
            guard release.wait(timeout: .now() + 5) == .success else {
                throw AoaError.usb("test failed to release blocked DATA")
            }
            lock.withLock { failed = true }
            throw AoaError.usb("injected partial USB write")
        }
        try wire.write(data)
    }
}

func runWriteFailureChecks() throws {
    let wire = FailingWriteWire()
    let failing = DispatchSemaphore(value: 0)
    let finishFailure = DispatchSemaphore(value: 0)
    let mux = AoaMultiplexer(transport: wire) { _ in
        failing.signal()
        _ = finishFailure.wait(timeout: .now() + 3)
    }
    Thread.detachNewThread {
        do {
            let reset = try wire.wire.next()
            wire.wire.feed(try AoaFrame(type: .resetOK, streamID: 0, payload: reset.payload))
        } catch { fatalError("write failure handshake: \(error)") }
    }
    let ports = try mux.start(relayPort: 0, pairingPort: 0)
    defer { wire.release.signal(); finishFailure.signal(); mux.stop() }
    let client = try connectLocal(ports.relay)
    defer { Darwin.close(client) }
    let opened = try wire.wire.next()
    wire.wire.feed(try AoaFrame(type: .openOK, streamID: opened.streamID))
    var byte: UInt8 = 1
    check(Darwin.send(client, &byte, 1, 0) == 1, "send DATA for injected failure")
    check(wire.writing.wait(timeout: .now() + 3) == .success, "USB write entered")

    // Return-credit writes queue behind the stalled DATA while real socket delivery succeeds.
    for _ in 0..<8 {
        wire.wire.feed(try AoaFrame(type: .data, streamID: opened.streamID, payload: Data([2])))
        check(Darwin.recv(client, &byte, 1, MSG_WAITALL) == 1 && byte == 2, "peer data delivered")
    }
    wire.release.signal()
    check(failing.wait(timeout: .now() + 3) == .success, "failed session retired")
    // Keep failure reporting busy: queued writes must still never touch the failed transport.
    let attempted = wire.wroteAfterFailure.wait(timeout: .now() + 0.3) == .success
    finishFailure.signal()
    check(!attempted, "queued frames must not write after a partial transfer failure")
    print("AOA failed-write queue isolation check passed")
}
