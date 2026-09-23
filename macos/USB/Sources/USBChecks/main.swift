import Foundation
import DroidBridgeUSB

try runBulkPacketChecks()

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--list" {
    // Enumeration only: never open, claim, switch, or reset a device.
    for device in try LibusbAccessoryTransport.devices(libraryPath: CommandLine.arguments[2]) {
        print("\(device.id) \(device.name) accessory=\(device.isAccessory)")
    }
    exit(0)
}

func check(_ value: @autoclosure () -> Bool, _ label: String) {
    guard value() else { fatalError("FAIL: \(label)") }
}
func rejects(_ label: String, _ body: () throws -> Void) {
    do { try body(); fatalError("FAIL: accepted \(label)") } catch {}
}

let open = Data([0x44,0x42,0x41,0x4d, 1,1,2,0, 0,0,0,1, 0,0,0,0])
let openFrame = try AoaFrame(type: .open, streamID: 1, service: .pairing)
check(openFrame.encoded() == open, "literal pairing OPEN")
for split in 0...open.count {
    var decoder = AoaFrameDecoder()
    let first = try decoder.append(open.prefix(split))
    let rest = try decoder.append(open.dropFirst(split))
    check(first + rest == [openFrame], "split OPEN \(split)")
}
let data = Data([0x44,0x42,0x41,0x4d, 1,3,0,0, 0,0,0,3, 0,0,0,3, 1,2,3])
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
rejects("zero credit") { _ = try AoaFrame(type: .window, streamID: 1, payload: Data([0,0,0,0])) }
rejects("empty DATA") { _ = try AoaFrame(type: .data, streamID: 1) }
rejects("truncated frame") {
    var d = AoaFrameDecoder(); _ = try d.append(data.dropLast()); try d.finish()
}
print("AOA codec checks passed")
try runMuxChecks()
try runHandshakeChecks()
