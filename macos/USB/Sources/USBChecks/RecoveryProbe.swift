import Foundation
import DroidBridgeUSB

/// Opt-in device acceptance check. Stop/quit the GUI and restore another network first.
func runRecoveryProbe(libraryPath: String, location: String) throws {
    guard try LibusbAccessoryTransport.devices(libraryPath: libraryPath).contains(where: {
        $0.location == location && $0.isAccessory
    }) else { throw AoaError.usb("recovery probe requires an already attached accessory") }

    // Establish a clean boundary before injecting exactly one malformed header.
    let baseline = AoaMultiplexer(transportFactory: {
        try LibusbAccessoryTransport(libraryPath: libraryPath, location: location)
    })
    _ = try baseline.start(relayPort: 0, pairingPort: 0)
    baseline.stop()
    let fault = try LibusbAccessoryTransport(libraryPath: libraryPath, location: location)
    do { try fault.write(Data(repeating: 0, count: 16)) }
    catch { fault.close(); throw error }
    fault.close()
    print("Injected one malformed AOA header; waiting for Android reopen")
    Thread.sleep(forTimeInterval: 2)

    let recovered = AoaMultiplexer(transportFactory: {
        try LibusbAccessoryTransport(libraryPath: libraryPath, location: location)
    })
    defer { recovered.stop() }
    _ = try recovered.start(relayPort: 0, pairingPort: 0)
    check(recovered.isConnected, "fresh RESET after Android automatic reopen")
    print("AOA device automatic-reopen probe passed (fresh RESET handshake)")
}
