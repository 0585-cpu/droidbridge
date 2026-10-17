import Foundation
import DroidBridgeUSB

func runReliableChannelChecks() throws {
    let epoch = Data(0..<16)
    var host = ReliableUsbState(epoch: epoch, now: 0)
    var phone = ReliableUsbState(epoch: nil, now: 0)
    let hello = try host.next(now: 0)!
    _ = try phone.receive(hello, now: 0)
    // Lose the first HELLO_ACK; a repeated HELLO must not reset the established epoch.
    _ = try phone.next(now: 0)
    _ = try phone.receive(host.next(now: 0.5)!, now: 0.5)
    _ = try host.receive(phone.next(now: 0.5)!, now: 0.5)
    for i in 0..<32 {
        let accepted = try host.offer(Data([UInt8(i)]), now: 1)
        check(accepted, "reliable bounded window accepts capacity")
    }
    let full = try host.offer(Data([99]), now: 1)
    check(!full, "reliable full window backpressures")
    let lost = try host.next(now: 1)!
    let reordered = try host.next(now: 1)!
    let gap = try phone.receive(reordered, now: 1)
    check(gap == nil, "out of order DATA never reaches AOA")
    _ = try host.receive(phone.next(now: 1)!, now: 1)
    let stillFull = try host.offer(Data([99]), now: 1)
    check(!stillFull, "duplicate ACK never expands window")
    // Deliver the missing DATA then deliberately lose its ACK.
    let delivered = try phone.receive(lost, now: 1)
    check(delivered == Data([0]), "contiguous DATA delivered")
    let lostAck = try phone.next(now: 1.002)
    check(lostAck?.kind == .ack,"loss fixture discards a real delayed ACK")
    let retry = try host.next(now: 1.5)!
    check(retry.sequence == 1, "oldest unacknowledged DATA retried")
    let duplicate = try phone.receive(retry, now: 1.5)
    check(duplicate == nil, "retry delivered exactly once")
    _ = try host.receive(phone.next(now: 1.5)!, now: 1.5)
    let freed = try host.offer(Data([32]), now: 1.5)
    check(freed, "cumulative ACK frees one slot")
    var output = Data([0])
    for _ in 0..<32 {
        let packet = try host.next(now: 2)!
        if let payload = try phone.receive(packet, now: 2) { output.append(payload) }
        if let ack = try phone.next(now: 2) { _ = try host.receive(ack, now: 2) }
    }
    check(output == Data(0...32), "loss and reorder preserve complete byte order")
    check(host.nextWakeAt(now:2) == nil,"batched ACKs drain the complete window")
    rejects("future ACK") { _ = try host.receive(ReliableUsbRecord(kind: .ack, epoch: epoch, ack: 34), now: 2) }
    let old = try ReliableUsbRecord(kind: .data, epoch: Data(repeating: 8, count: 16), sequence: 1, payload: Data([88]))
    let ignored = try phone.receive(old, now: 2)
    check(ignored == nil, "old epoch DATA ignored")
    rejects("epoch change requires clean physical session") {
        _ = try phone.receive(ReliableUsbRecord(kind: .hello, epoch: old.epoch), now: 2)
    }
    _ = try host.offer(Data([44]), now: 3)
    _ = try host.next(now: 3)
    _ = try host.next(now: 13) // a phone freeze shorter than the deadline keeps the session
    rejects("no progress deadline") { _ = try host.next(now: 3 + ReliableUsbState.noProgressSeconds) }
    var fair = ReliableUsbState(epoch: epoch, now: 0)
    _ = try fair.receive(ReliableUsbRecord(kind: .helloAck, epoch: epoch), now: 0)
    _ = try fair.offer(Data([42]), now: 0)
    _ = try fair.receive(ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 1, payload: Data([7])), now: 0)
    let piggyback = try fair.next(now: 0)!
    check(piggyback.kind == .data && piggyback.ack == 1, "incoming ACK demand cannot starve outgoing DATA")
    var waiting = ReliableUsbState(epoch: epoch, now: 0)
    rejects("incompatible or absent peer handshake") { _ = try waiting.next(now: 10) }
    print("Reliable USB handshake, window, loss, ACK replay, epoch and deadline checks passed")
}


private final class ReliablePipe: AoaByteTransport, @unchecked Sendable {
    let condition = NSCondition()
    var incoming: [Data] = []
    var stopped = false
    weak var peer: ReliablePipe?
    var lostData = false
    var lostAck = false
    var duplicateData = false
    func readChunk() throws -> Data? {
        condition.lock(); defer { condition.unlock() }
        while incoming.isEmpty && !stopped { condition.wait() }
        return stopped ? nil : incoming.removeFirst()
    }
    func write(_ data: Data) throws {
        let closed = condition.withLock { stopped }
        if closed { throw AoaError.usb("test pipe closed") }
        var decoder = ReliableUsbDecoder()
        let record = try decoder.append(data).first!
        if record.kind == .ack && !lostAck { lostAck = true; return }
        var bytes = data
        if record.kind == .data && !lostData && record.payload.count > 1024 {
            lostData = true; bytes = Data(data.dropFirst(1024))
        } else if record.kind == .data && !duplicateData {
            duplicateData = true; bytes.append(data)
        }
        guard let peer else { throw AoaError.usb("test pipe disconnected") }
        peer.condition.withLock {
            var offset = 0
            while offset < bytes.count {
                let end = min(offset+4096,bytes.count)
                peer.incoming.append(Data(bytes[offset..<end])); offset = end
            }
            peer.condition.broadcast()
        }
    }
    func close() { condition.withLock { stopped = true; condition.broadcast() } }
}

private final class ReliableResults: @unchecked Sendable {
    let lock = NSLock()
    var errors: [String] = []
    func record(_ error: any Error) { lock.withLock { errors.append(String(describing:error)) } }
}

func runReliableIOChecks() throws {
    let left = ReliablePipe(), right = ReliablePipe()
    left.peer = right; right.peer = left
    let host = ReliableUsbTransport(raw: left, epoch: Data(0..<16))
    let phone = ReliableUsbTransport(raw: right, epoch: nil)
    defer { host.close(); phone.close() }
    let payload = Data((0..<1_048_576).map { UInt8(truncatingIfNeeded: $0*13) })
    let group = DispatchGroup(), results = ReliableResults()
    for endpoint in [host,phone] {
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            do { try endpoint.write(payload) } catch { results.record(error) }
        }
        group.enter()
        Thread.detachNewThread {
            defer { group.leave() }
            do {
                var output = Data()
                while output.count < payload.count {
                    guard let bytes = try endpoint.readChunk() else { throw AoaError.usb("early test EOF") }
                    output.append(bytes)
                }
                if output != payload { throw AoaError.usb("duplex bytes differ") }
            } catch { results.record(error) }
        }
    }
    let completed = group.wait(timeout: .now()+10) == .success
    host.close(); phone.close()
    check(completed && results.lock.withLock { results.errors.isEmpty }, "duplex 1 MiB loss/ACK loss/duplicate exact delivery")

    // With no reader to acknowledge, a writer must wake on Stop, not wait forever.
    let blockedRaw = ReliablePipe(), blockedPeer = ReliablePipe()
    blockedRaw.peer = blockedPeer; blockedPeer.peer = blockedRaw
    let blocked = ReliableUsbTransport(raw: blockedRaw, epoch: Data(0..<16))
    let finished = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do { try blocked.write(payload); results.record(AoaError.usb("unexpected blocked write success")) } catch {}
        finished.signal()
    }
    blocked.close()
    check(finished.wait(timeout: .now()+2) == .success, "Stop wakes handshake/window writer")
    check(results.lock.withLock { results.errors.isEmpty }, "no unexpected IO results")
    print("Reliable USB duplex corruption, ACK loss, duplicate and cancellation checks passed")
}
