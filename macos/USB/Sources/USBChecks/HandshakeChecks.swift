import Foundation
import DroidBridgeUSB

final class ControlProbe: AoaControlDevice {
    var requests: [(UInt8, UInt16, Data)] = []
    var version = Data([2,0])
    func controlIn(request: UInt8, length: UInt16) throws -> Data {
        check(request == 51 && length == 2, "AOA version probe")
        return version
    }
    func controlOut(request: UInt8, index: UInt16, data: Data) throws {
        requests.append((request, index, data))
    }
}
func runHandshakeChecks() throws {
    let probe = ControlProbe()
    try AoaHandshake.switchToAccessory(probe, serial: "test-phone")
    check(probe.requests.count == 7, "six identities before mode switch")
    check(probe.requests[0].0 == 52 && probe.requests[0].1 == 0 &&
          probe.requests[0].2 == Data("DroidBridge\0".utf8), "manufacturer with terminator")
    check(probe.requests[3].2 == Data("1\0".utf8), "version supplied for older Android")
    check(probe.requests[6].0 == 53 && probe.requests[6].2.isEmpty, "switch last")
    for bad in [Data(), Data([1]), Data([0,0]), Data([0,1])] {
        let unsupported = ControlProbe(); unsupported.version = bad
        rejects("unsupported accessory protocol") { try AoaHandshake.switchToAccessory(unsupported, serial: "x") }
        check(unsupported.requests.isEmpty, "no switch on unsupported device")
    }
    print("AOA handshake checks passed")
}
