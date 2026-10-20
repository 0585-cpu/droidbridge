import Foundation
import DroidBridgeUSB

private final class RecoverySession: AoaMultiplexing, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = false
    private var stopped = false
    private var services: Set<AoaFrame.Service> = []
    let failStart: Bool
    let gate: DispatchSemaphore?
    let disconnected: @Sendable (String) -> Void
    init(failStart: Bool, gate: DispatchSemaphore?, disconnected: @escaping @Sendable (String) -> Void) {
        self.failStart = failStart; self.gate = gate; self.disconnected = disconnected
    }
    var isConnected: Bool { lock.withLock { connected && !stopped } }
    var isStopped: Bool { lock.withLock { stopped } }
    var enabled: Set<AoaFrame.Service> { lock.withLock { services } }
    func start() throws {
        gate?.wait()
        try lock.withLock {
            if failStart || stopped { throw AoaError.usb("injected transport failure") }
            connected = true
        }
    }
    func stop() { lock.withLock { stopped = true; connected = false }; gate?.signal(); disconnected("closed") }
    func setEnabled(_ services: Set<AoaFrame.Service>) { lock.withLock { self.services = services } }
    func fail() { lock.withLock { connected = false }; disconnected("USB write timeout") }
}

private final class RecoveryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RecoverySession] = []
    private var recoveredCount = 0
    var failRetries = false
    var retryGate: DispatchSemaphore?
    var sessions: [RecoverySession] { lock.withLock { items } }
    var recoveries: Int { lock.withLock { recoveredCount } }
    func recovered() { lock.withLock { recoveredCount += 1 } }
    func make(_ serial: String, _ recovering: Bool, _ callback: @escaping @Sendable (String) -> Void) -> any AoaMultiplexing {
        precondition(serial == "aoa:test-phone", "Recovery must use the selected USB location")
        let result = RecoverySession(failStart: recovering && failRetries, gate: recovering ? retryGate : nil, disconnected: callback)
        lock.withLock { items.append(result) }
        return result
    }
}

private func awaitRecovery(_ label: String, _ predicate: () async -> Bool) async throws {
    for _ in 0..<300 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw AoaError.usb("timed out: \(label)")
}

func runAoaRecoveryChecks() async throws {
    let factory = RecoveryFactory()
    let link = AoaDeviceLink(sessionFactory: factory.make, retryDelays: [.milliseconds(10), .milliseconds(10), .milliseconds(10)])
    await link.setRecoveryHandler { factory.recovered() }
    try await link.forward(serial: "aoa:test-phone", hostPort: 27183, devicePort: 27183)
    factory.sessions[0].fail()
    try await awaitRecovery("automatic USB reopen") { factory.recoveries == 1 }
    precondition(factory.sessions.count == 2 && factory.sessions[1].isConnected)
    precondition(factory.sessions[1].enabled == [.relay], "Recovery must preserve the requested services")
    factory.sessions[0].fail()
    try await Task.sleep(for: .milliseconds(40))
    precondition(factory.sessions.count == 2, "Stale callbacks must not tear down the replacement")
    try await link.removeForward(serial: "aoa:test-phone", hostPort: 27183)
    precondition(factory.sessions[1].isStopped)

    // Sleep closes the session without a recovery storm; wake reopens it with the same services.
    let sleeping = RecoveryFactory()
    let sleeper = AoaDeviceLink(sessionFactory: sleeping.make, retryDelays: [.milliseconds(10)])
    await sleeper.setRecoveryHandler { sleeping.recovered() }
    await sleeper.resumeAfterWake()
    try await Task.sleep(for: .milliseconds(30))
    precondition(sleeping.sessions.isEmpty, "Wake without a prior sleep opens nothing")
    try await sleeper.forward(serial: "aoa:test-phone", hostPort: 27183, devicePort: 27183)
    await sleeper.prepareForSleep()
    try await Task.sleep(for: .milliseconds(40))
    precondition(sleeping.sessions[0].isStopped && sleeping.sessions.count == 1, "Sleep closes the session and does not reopen it")
    await sleeper.resumeAfterWake()
    try await awaitRecovery("reopen after wake") { sleeping.recoveries == 1 }
    precondition(sleeping.sessions.count == 2 && sleeping.sessions[1].isConnected && sleeping.sessions[1].enabled == [.relay])
    try await sleeper.removeForward(serial: "aoa:test-phone", hostPort: 27183)
    await sleeper.prepareForSleep(); await sleeper.resumeAfterWake()
    try await Task.sleep(for: .milliseconds(30))
    precondition(sleeping.sessions.count == 2, "Sleep and wake leave a stopped relay closed")

    let bounded = RecoveryFactory(); bounded.failRetries = true
    let failing = AoaDeviceLink(sessionFactory: bounded.make, retryDelays: [.milliseconds(1), .milliseconds(1), .milliseconds(1)])
    try await failing.forward(serial: "aoa:test-phone", hostPort: 27183, devicePort: 27183)
    bounded.sessions[0].fail()
    try await awaitRecovery("bounded retries") { bounded.sessions.count == 4 }
    try await Task.sleep(for: .milliseconds(50))
    precondition(bounded.sessions.count == 4 && bounded.recoveries == 0)
    try await failing.removeForward(serial: "aoa:test-phone", hostPort: 27183)

    let blocked = RecoveryFactory(); blocked.retryGate = DispatchSemaphore(value: 0)
    let stopping = AoaDeviceLink(sessionFactory: blocked.make, retryDelays: [.milliseconds(1)])
    await stopping.setRecoveryHandler { blocked.recovered() }
    try await stopping.forward(serial: "aoa:test-phone", hostPort: 27183, devicePort: 27183)
    blocked.sessions[0].fail()
    try await awaitRecovery("in-flight USB reopen") { blocked.sessions.count == 2 }
    await stopping.suspendRecovery()
    try await stopping.removeForward(serial: "aoa:test-phone", hostPort: 27183)
    try await Task.sleep(for: .milliseconds(50))
    precondition(blocked.sessions[1].isStopped && blocked.recoveries == 0, "Stop must retire a pending USB open")

    let pairing = RecoveryFactory()
    let pairingLink = AoaDeviceLink(sessionFactory: pairing.make, retryDelays: [.milliseconds(1)])
    try await pairingLink.forward(serial: "aoa:test-phone", hostPort: 27184, devicePort: 27184)
    pairing.sessions[0].fail()
    try await Task.sleep(for: .milliseconds(50))
    precondition(pairing.sessions.count == 1, "Pairing alone must not enable automatic internet recovery")
    try await pairingLink.removeForward(serial: "aoa:test-phone", hostPort: 27184)
    print("AOA recovery checks: automatic reopen, stale callbacks, retry limit, Stop race, pairing isolation passed")
}
