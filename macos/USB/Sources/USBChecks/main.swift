import Foundation
import DroidBridgeUSB

if CommandLine.arguments.contains("--batching-checks") {
    try runBatchingChecks()
    exit(0)
}

if CommandLine.arguments.contains("--backpressure-checks") {
    try runBackpressureChecks()
    exit(0)
}

if CommandLine.arguments.contains("--reliable-record-checks") {
    try runReliableRecordChecks()
    try runReliableRetryChecks()
    try runReliableChannelChecks()
    try runReliableIOChecks()
    exit(0)
}

if CommandLine.arguments.count == 4 && CommandLine.arguments[1] == "--recovery-probe" {
    try runRecoveryProbe(libraryPath: CommandLine.arguments[2], location: CommandLine.arguments[3])
    exit(0)
}

try runBulkPacketChecks()
try runWriteTraceChecks()
try runBatchingChecks()

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--list" {
    // Enumeration only: never open, claim, switch, or reset a device.
    for device in try LibusbAccessoryTransport.devices(libraryPath: CommandLine.arguments[2]) {
        print("\(device.id) \(device.name) accessory=\(device.isAccessory)")
    }
    exit(0)
}

try runReliableRecordChecks()
try runReliableRetryChecks()
try runReliableChannelChecks()
try runReliableIOChecks()

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fatalError("FAIL: \(label)") }
}
func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL: accepted \(label)") } catch {}
}

let open = Data([0x44,0x42,0x41,0x4d, 2,1,2,0, 0,0,0,1, 0,0,0,0])
let openFrame = try AoaFrame(type: .open, streamID: 1, service: .pairing)
check(openFrame.encoded() == open, "literal pairing OPEN")
for split in 0...open.count {
    var decoder = AoaFrameDecoder()
    let first = try decoder.append(open.prefix(split))
    let rest = try decoder.append(open.dropFirst(split))
    check(first + rest == [openFrame], "split OPEN \(split)")
}
let data = Data([0x44,0x42,0x41,0x4d, 2,3,0,0, 0,0,0,3, 0,0,0,3, 1,2,3])
var decoder = AoaFrameDecoder()
let frames = try decoder.append(open + data)
check(frames.count == 2 && frames[1].payload == Data([1,2,3]), "coalesced frames")
rejects("even stream") { _ = try AoaFrame(type: .fin, streamID: 2) }
rejects("unknown service") {
    var bytes = open; bytes[6] = 3
    var d = AoaFrameDecoder(); _ = try d.append(bytes)
}
rejects("allocation beyond frame cap") {
    var bytes = open; bytes[5] = 3; bytes[6] = 0; bytes[12] = 0x7f
    var d = AoaFrameDecoder(); _ = try d.append(bytes)
}
rejects("reserved bits") {
    var bytes = open; bytes[7] = 1
    var d = AoaFrameDecoder(); _ = try d.append(bytes)
}
rejects("legacy additive credit") { _ = try AoaFrame(type: .window, streamID: 1, payload: Data([0,0,0,0])) }
rejects("legacy frame version") {
    var bytes = open; bytes[4] = 1
    var d = AoaFrameDecoder(); _ = try d.append(bytes)
}
let cumulative = try AoaFrame(type: .window, streamID: 1, payload: AoaFrame.consumedBytes(0x100000123))
check(cumulative.encoded() == Data([0x44,0x42,0x41,0x4d, 2,6,0,0, 0,0,0,1, 0,0,0,8,
                                  0,0,0,1,0,0,1,0x23]), "literal cumulative WINDOW matches Android")
check(AoaFrame.consumedCount(cumulative.payload) == 0x100000123, "consumption survives 32 bit rollover")
_ = try AoaFrame(type: .window, streamID: 1, payload: AoaFrame.consumedBytes(0))
rejects("negative peer count") {
    _ = try AoaFrame(type: .window, streamID: 1, payload: AoaFrame.consumedBytes(UInt64.max))
}
rejects("empty DATA") { _ = try AoaFrame(type: .data, streamID: 1) }
rejects("truncated frame") {
    var d = AoaFrameDecoder(); _ = try d.append(data.dropLast()); try d.finish()
}
print("AOA codec checks passed")
try runWriteFailureChecks()
try runMuxChecks()
try runBackpressureChecks()
try runHandshakeChecks()
