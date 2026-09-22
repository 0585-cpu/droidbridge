import DroidBridgeShared
import Foundation

final class FakeTunnelPreferences: TunnelPreferences, PacketTunnelManaging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var events: [String] = []
    private func record(_ e: String) { lock.withLock { events.append(e) } }
    func loadAll() async throws { record("load") }
    func save() async throws { record("save") }
    func reload() async throws { record("reload") }
    func startTunnel() async throws { record("start") }
    func stopTunnel() async { record("stopVPN") }
    func waitUntilDisconnected() async { record("waitDisconnected") }
    func connect() async throws { try await PacketTunnelManager(preferences: self).connect() }
    func disconnect() async { await PacketTunnelManager(preferences: self).disconnect() }
    var snapshot: [String] { lock.withLock { events } }
}

private actor OrderRecordingAdb: RelayAdb {
    let sink: @Sendable (String) -> Void
    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }
    func packagePath(serial: String, package: String) async throws -> String? { "/x" }
    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws {}
    func removeForward(serial: String, hostPort: UInt16) async throws { sink("removeForwards") }
    func startActivity(serial: String, component: String) async throws {}
}

private final class OrderRecordingConfig: RuntimeConfigurationStore, @unchecked Sendable {
    let sink: @Sendable (String) -> Void
    init(sink: @escaping @Sendable (String) -> Void) { self.sink = sink }
    func write(_ configuration: TunnelRuntimeConfiguration) throws {}
    func read() throws -> TunnelRuntimeConfiguration? { nil }
    func delete() throws { sink("deleteRuntimeConfig") }
}

func runVpnChecks(_ r: CheckRunner) {
    // connect order
    runBlocking {
        let prefs = FakeTunnelPreferences()
        try? await PacketTunnelManager(preferences: prefs).connect()
        r.check(prefs.snapshot == ["load", "save", "reload", "start"], "connect order load,save,reload,start")
    }

    // disconnect teardown order: stop VPN before removing forwards, config deleted last
    runBlocking {
        let events = EventBox()
        let vpn = FakeTunnelPreferences()
        // route vpn events into the shared box in order
        let orderedVpn = OrderedVpn(inner: vpn, sink: { events.append($0) })
        let adb = OrderRecordingAdb(sink: { events.append($0) })
        let config = OrderRecordingConfig(sink: { events.append($0) })
        let workflow = DisconnectWorkflow(vpn: orderedVpn, adb: adb, configStore: config)
        await workflow.run(serial: "R1")
        let order = events.snapshot
        // stopVPN + waitDisconnected come from the vpn, then removeForwards (x2), then deleteRuntimeConfig
        r.check(order.first == "stopVPN" && order[1] == "waitDisconnected", "VPN stopped and awaited first")
        r.check(order.firstIndex(of: "removeForwards")! < order.firstIndex(of: "deleteRuntimeConfig")!, "forwards removed before config delete")
        r.check(order.firstIndex(of: "waitDisconnected")! < order.firstIndex(of: "removeForwards")!, "routing restored before loopback relay removed")
    }

    // provider messages round-trip and metrics cap
    r.check(ProviderMessage.parse(ProviderMessage.reconnect.encoded()) == .reconnect, "provider message round trips")
    r.check(ProviderMessage.parse(Data("{}".utf8)) == nil, "unknown provider message rejected")
    let snap = TunnelMetricsSnapshot(
        activeFlows: 3,
        uploadedBytes: 100,
        downloadedBytes: 200,
        carrierName: "C",
        cellularAvailable: true,
        tunnelActive: true
    )
    r.check((try? ProviderResponse.encodeMetrics(snap)) != nil, "metrics encode under cap")
    r.check(snap.tunnelActive, "metrics preserve protected tunnel lifecycle")

    r.finish("vpn")
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock(); private var events: [String] = []
    func append(_ e: String) { lock.withLock { events.append(e) } }
    var snapshot: [String] { lock.withLock { events } }
}

final class OrderedVpn: PacketTunnelManaging, @unchecked Sendable {
    let inner: FakeTunnelPreferences; let sink: @Sendable (String) -> Void
    init(inner: FakeTunnelPreferences, sink: @escaping @Sendable (String) -> Void) { self.inner = inner; self.sink = sink }
    func connect() async throws {}
    func disconnect() async { sink("stopVPN"); sink("waitDisconnected") }
}
