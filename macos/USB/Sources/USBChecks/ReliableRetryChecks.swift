import Foundation
import DroidBridgeUSB

func runReliableRetryChecks() throws {
    let epoch = Data(0..<16)
    func ready(_ host: Bool = true) throws -> ReliableUsbState {
        var state = ReliableUsbState(epoch: host ? epoch : nil, now: 0)
        _ = try state.receive(ReliableUsbRecord(kind: host ? .helloAck : .hello, epoch: epoch), now: 0)
        if !host { _ = try state.next(now: 0) }
        return state
    }

    // A fixed 500 ms retry loop sends 608 duplicate records over this stalled 10 s window.
    for isHost in [true, false] {
        var state = try ready(isHost)
        for _ in 0..<32 { let accepted = try state.offer(Data(repeating: 7, count: 16384), now: 0); check(accepted, "window accepts 32") }
        let full = try state.offer(Data([1]), now: 0)
        check(!full, "backoff does not enlarge the 32-record window")
        var sends = 0
        for millis in stride(from: 0, through: 9500, by: 500) {
            while try state.next(now: Double(millis)/1000) != nil { sends += 1 }
        }
        print("stalled_window host=\(isHost) durationMs=10000 sends=\(sends) retries=\(state.retransmissions)")
        check(state.retransmissions == 192 && sends == 224, "stalled records back off to 500/1000/2000 ms")
        rejects("adaptive retry must preserve the no-progress deadline") { _ = try state.next(now: ReliableUsbState.noProgressSeconds) }
    }

    var intervals = try ready()
    _ = try intervals.offer(Data([1]), now: 0)
    for (time, next): (Double, Double) in [(0,0.5), (0.5,1.5), (1.5,3.5), (3.5,5.5)] {
        let packet = try intervals.next(now: time)
        check(packet?.sequence == 1, "retry occurs at scheduled interval")
        let early = try intervals.next(now: next-0.001)
        check(early == nil, "no retry before scheduled interval")
    }

    var progress = try ready()
    for value in 0..<2 { _ = try progress.offer(Data([UInt8(value)]), now: 0) }
    for time in [0.0,0.5,1.5] { for _ in 0..<2 { _ = try progress.next(now: time) } }
    _ = try progress.receive(ReliableUsbRecord(kind: .ack, epoch: epoch, ack: 1), now: 1.6)
    let afterProgress = try progress.next(now: 1.6)
    check(afterProgress == nil, "ACK progress does not immediately retrigger old records")
    _ = try progress.offer(Data([3]), now: 1.7)
    for time in [1.7,2.2,3.2] {
        let fresh = try progress.next(now: time)
        check(fresh?.sequence == 3, "new records keep independent retry intervals")
    }
    for time in [3.5,4.0] {
        let reset = try progress.next(now: time)
        check(reset?.sequence == 2, "ACK progress resets future interval without changing scheduled retry")
    }
    _ = try progress.receive(ReliableUsbRecord(kind: .ack, epoch: epoch, ack: 1), now: 4.05)
    let afterDuplicate = try progress.next(now: 4.5)
    check(afterDuplicate == nil, "duplicate ACK never resets backoff")
    let nextRetry = try progress.next(now: 5)
    check(nextRetry?.sequence == 2, "next interval survives duplicate ACK")
    let freshRetry = try progress.next(now: 5.2)
    check(freshRetry?.sequence == 3, "other records keep their own retry schedule")
    let afterDuplicateInterval = try progress.next(now: 6)
    check(afterDuplicateInterval == nil, "duplicate ACK cannot shorten future retry intervals")
    rejects("only cumulative ACK progress extends deadline") { _ = try progress.next(now: 1.6 + ReliableUsbState.noProgressSeconds) }

    var fair = try ready()
    _ = try fair.offer(Data([42]), now: 0)
    for time in [0.0,0.5,1.5] { _ = try fair.next(now: time) }
    _ = try fair.receive(ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 1, payload: Data([7])), now: 1.6)
    let ack = try fair.next(now: 1.602)
    check(ack?.kind == .ack && ack?.ack == 1, "backed-off DATA cannot delay peer ACK")
    _ = try fair.receive(ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 2, payload: Data([8])), now: 3.5)
    let piggyback = try fair.next(now: 3.5)
    check(piggyback?.kind == .data && piggyback?.ack == 2, "due DATA still piggybacks ACK under receive load")

    var sender = try ready(), receiver = try ready(false)
    var decoder = ReliableUsbDecoder()
    _ = try sender.offer(Data([4,5,6]), now: 0)
    var corrupt = try sender.next(now: 0)!.encoded()
    corrupt[corrupt.count-1] = 99
    let damaged = try decoder.append(corrupt)
    check(damaged.isEmpty, "damaged payload remains rejected")
    let retry = try decoder.append(sender.next(now: 0.5)!.encoded()).first!
    let payload = try receiver.receive(retry, now: 0.5)
    check(payload == Data([4,5,6]), "retry delivers intact payload")
    let lostAck = try receiver.next(now: 0.502)
    check(lostAck?.kind == .ack,"loss fixture discards a real delayed ACK")
    let premature = try sender.next(now: 1)
    check(premature == nil, "lost ACK does not cause a premature retry")
    let duplicate = try decoder.append(sender.next(now: 1.5)!.encoded()).first!
    let redelivered = try receiver.receive(duplicate, now: 1.5)
    check(redelivered == nil, "lost ACK cannot duplicate application bytes")
    _ = try sender.receive(receiver.next(now: 1.5)!, now: 1.5)
    let drained = try sender.next(now: 20)
    check(drained == nil, "fully acknowledged sender has no retry deadline")

    var resumed = try ready(), destination = try ready(false)
    for value in 0..<32 { _ = try resumed.offer(Data([UInt8(value)]), now: 0) }
    for time in [0.0,0.5,1.5] {
        for _ in 0..<32 { _ = try resumed.next(now: time) } // Simulate a paused/lossy receiver.
        _ = try resumed.receive(ReliableUsbRecord(kind: .ack, epoch: epoch), now: time)
    }
    let paused = try resumed.next(now: 2)
    check(paused == nil, "paused receive path does not trigger fixed 500 ms retries")
    var output = Data()
    for _ in 0..<32 {
        if let bytes = try destination.receive(resumed.next(now: 3.5)!, now: 3.5) { output.append(bytes) }
        if let ack = try destination.next(now:3.5) { _ = try resumed.receive(ack,now:3.5) }
    }
    check(output == Data(0..<32), "resumed full window drains in exact order")
    check(resumed.nextWakeAt(now:3.5) == nil,"batched ACKs release all resumed records")
    let accepted = try resumed.offer(Data([32]), now: 3.501)
    let freshPayload = try destination.receive(resumed.next(now: 3.501)!, now: 3.501)
    check(accepted && freshPayload == Data([32]), "drained window accepts new records")
    print("Reliable USB adaptive retry, ACK progress, integrity, resume and deadline checks passed")
}
