import Foundation
import DroidBridgeUSB

func runReliableRecordChecks() throws {
    let epoch = Data(0..<16)
    // Independent Python struct.pack + hashlib vector, including >32-bit sequence/ACK.
    let literal = "444252334c494e4b0300000000000003000102030405060708090a0b0c0d0e0f00000001000000020000000100000001039058c6f2c0cb492c533b0a4d14ef77c9d50a3983ff2db1dc4ccf5db61492fa010203"
    let vector = try ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 0x100000002,
                                       ack: 0x100000001, payload: Data([1,2,3])).encoded()
    check(vector.map { String(format: "%02x", $0) }.joined() == literal, "independent reliable wire vector")
    let first = try ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 1, ack: 0,
                                      payload: Data(repeating: 42, count: 16384)).encoded()
    let next = try ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 2, ack: 0,
                                     payload: Data([9,8,7])).encoded()
    for lost in [512,1024,16384] {
        var decoder = ReliableUsbDecoder()
        let recovered = try decoder.append(first.dropFirst(lost) + next)
        check(recovered.map(\.sequence) == [2] && recovered.first?.payload == Data([9,8,7]), "lost USB prefix is not delivered as valid bytes")
    }
    for split in 0...next.count {
        var decoder = ReliableUsbDecoder()
        let recovered = try decoder.append(next.prefix(split)) + decoder.append(next.dropFirst(split))
        check(recovered.count == 1 && recovered[0].sequence == 2 && recovered[0].payload == Data([9,8,7]), "split reliable record")
    }
    var bad = try ReliableUsbRecord(kind: .data, epoch: epoch, sequence: 3, ack: 0,
                                    payload: Data("payloadDBR3LINKpayload".utf8)).encoded()
    bad[bad.count-1] = 0
    var decoder = ReliableUsbDecoder()
    let afterBad = try decoder.append(bad + next)
    check(afterBad.map(\.sequence) == [2], "bad digest with embedded magic skipped")
    for _ in 0..<100 {
        let garbage = try decoder.append(Data(repeating: 0x55, count: 16384))
        check(garbage.isEmpty, "bounded garbage scan")
    }
    let afterGarbage = try decoder.append(next)
    check(afterGarbage.count == 1, "decoder recovers after bounded garbage")
    var badLength = next; badLength[12] = 0x7f
    let afterLength = try decoder.append(badLength + next)
    check(afterLength.count == 1, "oversized length cannot hide subsequent valid record")
    var inRange = next; inRange[14] = 0x40; inRange[15] = 0
    let afterInRange = try decoder.append(inRange + next)
    check(afterInRange.count == 1, "damaged in-range length cannot hide small retry")
    rejects("negative reliable ACK") { _ = try ReliableUsbRecord(kind: .ack, epoch: epoch, ack: UInt64.max) }
    rejects("zero DATA sequence") { _ = try ReliableUsbRecord(kind: .data, epoch: epoch, payload: Data([1])) }
    print("Reliable USB record loss/resynchronization checks passed")
}
