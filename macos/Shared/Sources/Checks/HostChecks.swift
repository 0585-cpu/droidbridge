import DroidBridgeShared
import Foundation

private actor RecordingAdb: RelayAdb {
    private(set) var removedPorts: [UInt16] = []
    func packagePath(serial: String, package: String) async throws -> String? { "/x" }
    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws {}
    func removeForward(serial: String, hostPort: UInt16) async throws { removedPorts.append(hostPort) }
    func startActivity(serial: String, component: String) async throws {}
    var removed: [UInt16] { removedPorts }
}

func runHostChecks(_ r: CheckRunner) async {
    let readyHealth = RelayHealth(status: .ready, activeSessions: 0, maximumSessions: 128, uploadedBytes: 0, downloadedBytes: 0, carrierName: "C")
    let deviceA = AdbDevice(serial: "A", state: .authorized, model: "Galaxy")
    let deviceB = AdbDevice(serial: "B", state: .authorized, model: "Pixel")

    // USB removal from relayReady clears forwards but keeps pairing
    let adb = RecordingAdb()
    let store = InMemoryPairingSecretStore()
    try? store.save(Data(repeating: 1, count: 32), peerId: "peer")
    let core = DroidBridgeCoordinatorCore(state: .relayReady(health: readyHealth), adb: adb, secretStore: store, preparedSerial: "A")
    await core.deviceSnapshotChanged([])
    let s1 = await core.state
    let removed = await adb.removed.sorted()
    r.check(s1 == .deviceMissing, "device removal -> deviceMissing")
    r.check(removed == [27183, 27184], "device removal clears both forwards")
    r.check(store.deleteCount == 0, "device removal keeps the secret")

    let corePresent = DroidBridgeCoordinatorCore(
        state: .relayReady(health: readyHealth),
        adb: RecordingAdb(),
        secretStore: InMemoryPairingSecretStore(),
        preparedSerial: "A"
    )
    await corePresent.deviceSnapshotChanged([deviceA])
    r.check(await corePresent.state == .relayReady(health: readyHealth),
            "present prepared device preserves relay-ready state")

    // multiple devices requires selection
    let core2 = DroidBridgeCoordinatorCore(adb: RecordingAdb(), secretStore: InMemoryPairingSecretStore())
    await core2.deviceSnapshotChanged([deviceA, deviceB])
    let s2 = await core2.state
    r.check(s2 == .deviceSelectionRequired([deviceA, deviceB]), "two devices require selection")

    // single authorized device -> ready
    let core3 = DroidBridgeCoordinatorCore(adb: RecordingAdb(), secretStore: InMemoryPairingSecretStore())
    await core3.deviceSnapshotChanged([deviceA])
    let s3 = await core3.state
    r.check(s3 == .deviceReady(deviceA), "single authorized device is ready")

    // User workflow publishes pairing/SAS/relay-preparation states in order.
    await core3.beginPairing()
    r.check(await core3.state == .pairing(sas: nil), "pairing starts without a SAS")
    await core3.showPairingCode("123456")
    r.check(await core3.state == .pairing(sas: "123456"), "pairing publishes the SAS")
    await core3.beginRelayPreparation()
    r.check(await core3.state == .relayPreparing, "relay preparation publishes progress")
    await core3.deviceSelected(deviceA)
    r.check(await core3.state == .deviceReady(deviceA), "workflow can return to selected device")

    // unauthorized guidance
    let core4 = DroidBridgeCoordinatorCore(adb: RecordingAdb(), secretStore: InMemoryPairingSecretStore())
    await core4.deviceSnapshotChanged([AdbDevice(serial: "U", state: .unauthorized)])
    let s4 = await core4.state
    r.check(s4 == .deviceUnauthorized(serial: "U"), "unauthorized device shows guidance")

    // Disconnect keeps secret; Forget deletes it
    let adb5 = RecordingAdb()
    let store5 = InMemoryPairingSecretStore()
    try? store5.save(Data(repeating: 2, count: 32), peerId: "peer")
    let core5 = DroidBridgeCoordinatorCore(state: .relayReady(health: readyHealth), adb: adb5, secretStore: store5, preparedSerial: "A")
    await core5.disconnect()
    r.check(store5.deleteCount == 0, "disconnect keeps the secret")
    let removed5 = await adb5.removed.sorted()
    r.check(removed5 == [27183, 27184], "disconnect removes forwards")
    await core5.forget(peerId: "peer")
    r.check(store5.deleteCount == 1, "forget deletes the secret")

    r.finish("host")
}
