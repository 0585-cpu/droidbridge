import Foundation
import DroidBridgeShared

private struct HealthCheckFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
private func healthRequire(_ condition: Bool, _ message: String) throws {
    if !condition { throw HealthCheckFailure(message: message) }
}
private func healthEventually(_ condition: () -> Bool) async throws {
    let limit = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < limit {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw HealthCheckFailure(message: "health monitor did not reach expected probe")
}
private final class HealthPackets: PacketSource, @unchecked Sendable {
    private let lock = NSLock()
    private var reader: (@Sendable ([Data]) -> Void)?
    func read(_ handler: @escaping @Sendable ([Data]) -> Void) { lock.withLock { reader = handler } }
    func write(_ packets: [Data]) {}
    func submit(_ byte: UInt8) { lock.withLock { reader }?([Data([byte])]) }
}
private final class HealthIngester: PacketIngesting, @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [Data] = []
    func ingest(_ packet: Data) { lock.withLock { packets.append(packet) } }
    var received: [Data] { lock.withLock { packets } }
}
private let healthyProbeResponse = RelayHealth(status: .ready, activeSessions: 1, maximumSessions: 128,
                                               uploadedBytes: 10, downloadedBytes: 20, carrierName: "Fixture")
private final class HealthScript: @unchecked Sendable {
    private let lock = NSLock()
    private let results: [Result<RelayHealth, DroidBridgeError>]
    private var count = 0
    var beforeResult: ((Int) -> Void)?
    init(_ results: [Result<RelayHealth, DroidBridgeError>]) { self.results = results }
    var calls: Int { lock.withLock { count } }
    func probe() async throws -> RelayHealth {
        let result = lock.withLock { () -> Result<RelayHealth, DroidBridgeError>? in
            defer { count += 1 }
            return count < results.count ? results[count] : nil
        }
        beforeResult?(calls)
        if let result { return try result.get() }
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}
// Deliberately ignores cancellation until released, like a late transport callback.
private final class HeldHealthProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RelayHealth, Error>?
    var isWaiting: Bool { lock.withLock { continuation != nil } }
    func probe() async throws -> RelayHealth {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                precondition(self.continuation == nil)
                self.continuation = continuation
            }
        }
    }
    func release(_ result: Result<RelayHealth, DroidBridgeError>) {
        let pending = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        switch result {
        case .success(let health): pending?.resume(returning: health)
        case .failure(let error): pending?.resume(throwing: error)
        }
    }
}
private final class HealthWaits: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Duration] = []
    var delays: [Duration] { lock.withLock { values } }
    func wait(_ duration: Duration) async throws {
        try Task.checkCancellation()
        lock.withLock { values.append(duration) }
        await Task.yield()
        try Task.checkCancellation()
    }
}
private final class HealthEngines: @unchecked Sendable {
    private let lock = NSLock()
    private var controllers: [TunnelController] = []
    let packets = HealthPackets()
    let ingester = HealthIngester()
    var count: Int { lock.withLock { controllers.count } }
    func make() -> TunnelController {
        let ingester = self.ingester
        let controller = TunnelController(packetSource: packets, secret: Data(count: 32),
                                          engineFactory: { _, _ in ingester })
        lock.withLock { controllers.append(controller) }
        return controller
    }
    func stop() { lock.withLock { controllers }.forEach { $0.stop() } }
}
private struct HealthFixture {
    let service: HelperService
    let controller: TunnelController
    let engines = HealthEngines()
    let waits = HealthWaits()
    var packets: HealthPackets { engines.packets }
    var ingester: HealthIngester { engines.ingester }
    let configuration: TunnelRuntimeConfiguration
    init(_ script: HealthScript, stopCoordinator: HelperStopCoordinator = HelperStopCoordinator()) throws {
        try self.init(stopCoordinator: stopCoordinator, probe: { try await script.probe() })
    }
    init(stopCoordinator: HelperStopCoordinator = HelperStopCoordinator(),
         probe: @escaping @Sendable () async throws -> RelayHealth) throws {
        configuration = try TunnelRuntimeConfiguration(deviceSerial: "aoa:health-fixture", relayHost: "127.0.0.1",
            relayPort: 27183, pairedPeerId: "test", keychainAccount: "test", maximumFlows: 4)
        let waits = self.waits, engines = self.engines
        service = HelperService(stopCoordinator: stopCoordinator, healthProbe: { _, _ in try await probe() },
                                healthSleep: { try await waits.wait($0) })
        controller = engines.make()
        // The fake packet ingester has no native engine: no capability task, utun,
        // live network connection, privileged command, or phone access is started.
        precondition(controller.start())
        service.seedRelayForChecks(controller, configuration: configuration, status: .running,
                                   rebuild: { engines.make() })
    }
    var snapshot: TunnelMetricsSnapshot? {
        var result: TunnelMetricsSnapshot?
        service.status { result = try? JSONDecoder().decode(TunnelMetricsSnapshot.self, from: $0) }
        return result
    }
    var status: TunnelRuntimeStatus? { snapshot?.runtimeStatus }
    func monitor() -> Task<Void, Never> {
        let service = service, configuration = configuration
        let generation = service.healthGenerationForChecks
        return Task { await service.monitorRelay(configuration: configuration, secret: Data(count: 32),
                                                 generation: generation, immediately: true) }
    }
}

func runHealthProbeRecoveryChecks() async throws {
    // A failed status request must not retire the already authenticated data plane.
    let oneMiss = HealthScript([.failure(.relayTimedOut), .success(healthyProbeResponse)])
    let retained = try HealthFixture(oneMiss)
    let retaining = retained.monitor()
    defer { retaining.cancel(); retained.engines.stop() }
    try await healthEventually { oneMiss.calls >= 2 }
    retained.packets.submit(41)
    try healthRequire(retained.status == .running && retained.ingester.received == [Data([41])],
                      "one health timeout must preserve the original packet session during retry")
    try await healthEventually { oneMiss.calls >= 3 }
    retained.packets.submit(45)
    try healthRequire(retained.status == .running && retained.ingester.received == [Data([41]), Data([45])],
                      "health recovery must continue using the original packet session")
    retaining.cancel(); await retaining.value

    // Recovery resets the budget; separate short incidents must not accumulate.
    let intermittent = HealthScript([.failure(.relayTimedOut), .failure(.relayTimedOut), .success(healthyProbeResponse),
                                     .failure(.relayTimedOut), .failure(.relayTimedOut), .success(healthyProbeResponse)])
    let reset = try HealthFixture(intermittent)
    let resetting = reset.monitor()
    defer { resetting.cancel(); reset.engines.stop() }
    try await healthEventually { intermittent.calls >= 7 }
    reset.packets.submit(42)
    try healthRequire(reset.status == .running && reset.ingester.received == [Data([42])],
                      "successful health resets the consecutive timeout budget without replacing the packet session")
    resetting.cancel(); await resetting.value

    // A ~45 s phone freeze (six missed probes) must keep the original packet session.
    let frozen = HealthScript(Array(repeating: .failure(.relayTimedOut), count: 6) + [.success(healthyProbeResponse)])
    let survived = try HealthFixture(frozen)
    let surviving = survived.monitor()
    try await healthEventually { frozen.calls >= 8 }
    surviving.cancel(); await surviving.value
    survived.packets.submit(51)
    try healthRequire(survived.status == .running && survived.engines.count == 1 && survived.ingester.received == [Data([51])],
                      "a freeze within the retry budget must not replace or stop the packet session")
    survived.engines.stop()

    let exhausted = HealthScript(Array(repeating: .failure(.relayTimedOut), count: 7))
    let bounded = try HealthFixture(exhausted)
    let exhausting = bounded.monitor()
    try await healthEventually { exhausted.calls >= 8 }
    exhausting.cancel(); await exhausting.value
    bounded.packets.submit(43)
    try healthRequire(exhausted.calls >= 8 && bounded.status == .reconnecting && bounded.ingester.received.isEmpty,
                      "continued missing health stops packet processing after the finite retry budget")
    bounded.engines.stop()

    // Prolonged execution restrictions keep authenticated recovery alive at a low rate.
    let prolonged = HealthScript(Array(repeating: .failure(.relayTimedOut), count: 12) + [.success(healthyProbeResponse)])
    let recovered = try HealthFixture(prolonged)
    let recovering = recovered.monitor()
    defer { recovering.cancel(); recovered.engines.stop() }
    try await healthEventually { prolonged.calls >= 14 }
    recovered.packets.submit(47)
    try healthRequire(recovered.status == .running && recovered.engines.count == 2 &&
                      recovered.ingester.received == [Data([47])],
                      "late authenticated health must start a fresh packet engine without manual reconnect")
    try healthRequire(Array(recovered.waits.delays.prefix(12)) == [1,2,4,8,15,15,5,10,20,30,30,30].map { .seconds($0) },
                      "prolonged outage must back off to a bounded 30-second polling rate")
    recovering.cancel(); await recovering.value

    // Terminal credentials/protocol failures stop immediately; a later success must not be probed.
    for error in [DroidBridgeError.relayAuthenticationFailed, .relayProtocol("malformed fixture"), .secretWrongLength] {
      for prefix: [Result<RelayHealth, DroidBridgeError>] in [[], [.failure(.relayTimedOut)], Array(repeating: .failure(.relayTimedOut), count: 5)] {
        let explicitFailure = HealthScript(prefix + [.failure(error), .success(healthyProbeResponse)])
        let immediate = try HealthFixture(explicitFailure)
        let blocking = immediate.monitor()
        await blocking.value
        immediate.packets.submit(44)
        try healthRequire(explicitFailure.calls == prefix.count + 1 && immediate.status == .persistentBlockedRelay &&
                          immediate.engines.count == 1 && immediate.ingester.received.isEmpty,
                          "authentication/protocol failure must block and stop automatic recovery")
        immediate.engines.stop()
      }
    }
    let cellular = HealthScript([.failure(.cellularUnavailable), .success(healthyProbeResponse)])
    let restoredCellular = try HealthFixture(cellular)
    let cellularMonitor = restoredCellular.monitor()
    try await healthEventually { cellular.calls >= 3 }
    restoredCellular.packets.submit(48)
    try healthRequire(restoredCellular.status == .running && restoredCellular.engines.count == 2 &&
                      restoredCellular.ingester.received == [Data([48])],
                      "cellular unavailability remains fail-closed but authenticated recovery can restart")
    cellularMonitor.cancel(); await cellularMonitor.value; restoredCellular.engines.stop()

    // Explicit Stop intent may arrive while a health response is in flight, before lifecycle teardown.
    let stopDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: stopDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stopDirectory) }
    let stopStore = HelperRecoveryStateStore(url: stopDirectory.appendingPathComponent("stop.json"))
    let stop = HelperStopCoordinator(store: stopStore)
    let stoppedScript = HealthScript(Array(repeating: .failure(.relayTimedOut), count: 7) + [.success(healthyProbeResponse)])
    stoppedScript.beforeResult = { call in
        if call == 8 { try! stopStore.save(HelperRecoveryState(utun: "explicit-stop", pfEnableToken: nil)) }
    }
    let stopped = try HealthFixture(stoppedScript, stopCoordinator: stop)
    let stoppedMonitor = stopped.monitor()
    await stoppedMonitor.value
    stopped.packets.submit(49)
    try healthRequire(stoppedScript.calls == 8 && stopped.engines.count == 1 && stopped.status != .running &&
                      stopped.ingester.received.isEmpty, "Stop intent must fence a late healthy response before rebuilding")
    let callsAfterStop = stoppedScript.calls
    await stopped.service.monitorRelay(configuration: stopped.configuration, secret: Data(count: 32),
                                      generation: stopped.service.healthGenerationForChecks, immediately: true)
    try healthRequire(stoppedScript.calls == callsAfterStop, "pending Stop must prevent even a new health request")
    stopped.engines.stop()

    // A real suspension followed by cancellation must fence both late success and failure.
    for result: Result<RelayHealth, DroidBridgeError> in [.success(healthyProbeResponse), .failure(.relayAuthenticationFailed)] {
        let held = HeldHealthProbe()
        let current = try HealthFixture(probe: { try await held.probe() })
        let oldMonitor = current.monitor()
        defer {
            oldMonitor.cancel()
            held.release(.failure(.relayTimedOut))
            current.engines.stop()
        }
        try await healthEventually { held.isWaiting }
        oldMonitor.cancel()
        current.controller.stop()
        let engines = current.engines
        let successor = engines.make()
        try healthRequire(successor.start(), "successor packet controller must start")
        current.service.seedRelayForChecks(successor, configuration: current.configuration, status: .running,
                                           rebuild: { engines.make() })
        held.release(result)
        await oldMonitor.value
        current.packets.submit(46)
        try healthRequire(current.status == .running && current.snapshot?.carrierName == nil &&
                          current.engines.count == 2 && current.ingester.received == [Data([46])],
                          "late cancelled health results cannot update metrics, rebuild, or stop the successor packet session")
    }

    // EOF is a transport loss even though the shared transport reports relayProtocol.
    // It must not strand either a running session or the prolonged recovery loop.
    for message in ["peer closed", "truncated frame"] {
      for prefix: [Result<RelayHealth, DroidBridgeError>] in [[], Array(repeating: .failure(.relayTimedOut), count: 5)] {
        let eof = HealthScript(prefix + [.failure(.relayProtocol(message)), .success(healthyProbeResponse)])
        let resumed = try HealthFixture(eof)
        let eofMonitor = resumed.monitor()
        defer { eofMonitor.cancel(); resumed.engines.stop() }
        try await healthEventually { eof.calls >= prefix.count + 3 || resumed.status == .persistentBlockedRelay }
        eofMonitor.cancel(); await eofMonitor.value
        resumed.packets.submit(50)
        try healthRequire(eof.calls >= prefix.count + 3 && resumed.status == .running &&
                          resumed.engines.count == 2 && resumed.ingester.received == [Data([50])],
                          "transport EOF \(message) after \(prefix.count) timeouts must retry authenticated health and restore packet processing")
      }
    }
    print("helper health recovery: transient preservation, delayed automatic recovery, bounded polling, Stop fencing, terminal failure, held late results and transport EOF recovery checks passed")
}
