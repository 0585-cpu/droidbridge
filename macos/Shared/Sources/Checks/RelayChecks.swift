import DroidBridgeShared
import Foundation

private struct FixtureVector: Decodable { let name: String; let packet_hex: String }
private struct Fixtures: Decodable { let vectors: [FixtureVector] }

private func hexData(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}

private let fixtureSecret = hexData(String(repeating: "00", count: 31) + "01")

/// Fake DBP server backed by scripted response frames.
final class FakeDbpConnection: DbpConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: Data
    init(responseFrames: [Data]) { inbox = responseFrames.reduce(Data(), +) }
    func send(_ data: Data) async throws {}
    func receiveExactly(_ count: Int) async throws -> Data {
        try lock.withLock {
            guard inbox.count >= count else { throw DroidBridgeError.relayProtocol("peer closed") }
            let chunk = inbox.prefix(count); inbox.removeFirst(count); return Data(chunk)
        }
    }
    func close() async {}
}

private final class HangingDbpConnection: DbpConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func send(_ data: Data) async throws {}
    func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let shouldFail = lock.withLock {
                if closed { return true }
                waiters.append(continuation)
                return false
            }
            if shouldFail {
                continuation.resume(throwing: DroidBridgeError.relayProtocol("closed"))
            }
        }
    }
    func close() async {
        let pending = lock.withLock { () -> [CheckedContinuation<Data, Error>] in
            closed = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach {
            $0.resume(throwing: DroidBridgeError.relayProtocol("closed"))
        }
        // Closing a real transport can resume its receive before asynchronous
        // close cleanup finishes. The deadline must still be the reported cause.
        try? await Task.sleep(for: .milliseconds(20))
    }
    var wasClosed: Bool { lock.withLock { closed } }
}

private struct StubHealth: RelayHealthChecking {
    let result: Result<RelayHealth, DroidBridgeError>
    func health(secret: Data) async throws -> RelayHealth { try result.get() }
}

private actor StubAdb: RelayAdb {
    var packageInstalled = true
    var failRelayForward = false
    private(set) var removedForwards: [UInt16] = []
    private(set) var createdForwards: [UInt16] = []
    private(set) var startedActivity = false
    init(packageInstalled: Bool = true, failRelayForward: Bool = false) {
        self.packageInstalled = packageInstalled; self.failRelayForward = failRelayForward
    }
    func packagePath(serial: String, package: String) async throws -> String? { packageInstalled ? "/data/app/x.apk" : nil }
    func forward(serial: String, hostPort: UInt16, devicePort: UInt16) async throws {
        if hostPort == RelayPreparer.relayPort && failRelayForward { throw DroidBridgeError.forwardConflict(port: hostPort) }
        createdForwards.append(hostPort)
    }
    func removeForward(serial: String, hostPort: UInt16) async throws { removedForwards.append(hostPort) }
    func startActivity(serial: String, component: String) async throws { startedActivity = true }
    var removed: [UInt16] { removedForwards }
    var didStart: Bool { startedActivity }
}

func runRelayChecks(_ r: CheckRunner) async {
    // --- DBP fixture parity ---
    guard let data = DbpFixtures.v1JSON(),
          let fixtures = try? JSONDecoder().decode(Fixtures.self, from: data) else {
        r.check(false, "load dbp fixture"); r.finish("relay"); return
    }
    func packet(_ name: String) -> Data { hexData(fixtures.vectors.first { $0.name == name }!.packet_hex) }

    // decode header of each fixture and verify HMAC recomputes to the committed bytes
    for name in ["hello", "hello_ok", "open_ipv4_443", "open_domain_443", "open_ok", "open_error_policy_denied", "dns_query", "dns_response", "health", "health_response_ready"] {
        let p = packet(name)
        if let (header, hmac) = try? DbpCodec.decodeHeader(p) {
            let payload = p.suffix(p.count - 64)
            let recomputed = DbpCodec.computeHMAC(secret: fixtureSecret, header: header, payload: Data(payload))
            r.check(recomputed == hmac, "\(name): HMAC matches fixture")
            r.check(DbpCodec.encodeHeader(header, hmac: hmac) == p.prefix(64), "\(name): header re-encodes")
        } else { r.check(false, "\(name): decodes") }
    }

    // health payload parity
    let hr = packet("health_response_ready")
    if let health = try? DbpCodec.decodeHealth([UInt8](hr.suffix(hr.count - 64))) {
        r.check(health.status == .ready && health.maximumSessions == 128 && health.carrierName == "TestCarrier", "health payload decodes")
        r.check(health.isCellularReady, "ready health is cellular-ready")
    } else { r.check(false, "health decodes") }

    // open_tcp encoding parity
    if let open = try? DbpCodec.encodeOpenTcp(host: "example.com", port: 443) {
        r.check(open == packet("open_domain_443").suffix(15), "open_tcp domain encodes to fixture bytes")
    } else { r.check(false, "open_tcp encodes") }

    // --- RelayControlClient.health() over a fake server ---
    let clientNonce: UInt64 = 0x51 // we don't know it in advance; instead build a server that echoes
    _ = clientNonce
    // Build a fake server that responds correctly using the same secret. Since client nonce is random,
    // the fake must read it — but FakeDbpConnection is scripted. So we validate the failure paths here
    // and the happy path via a live-echo connection.
    let echo = EchoDbpServer(secret: fixtureSecret, health: RelayHealth(status: .ready, activeSessions: 0, maximumSessions: 128, uploadedBytes: 0, downloadedBytes: 0, carrierName: "Live"))
    let client = RelayControlClient(secret: fixtureSecret, connectionFactory: { echo.makeConnection() }, now: { 1_700_000_000 })
    do {
        let health = try await client.health()
        r.check(health.carrierName == "Live" && health.isCellularReady, "health() round trips over echo server")
    } catch { r.check(false, "health() echo failed: \(error)") }

    // wrong secret -> auth failure
    let badClient = RelayControlClient(secret: Data(count: 32), connectionFactory: { echo.makeConnection() }, now: { 1_700_000_000 })
    do { _ = try await badClient.health(); r.check(false, "wrong secret rejected") }
    catch { r.check(true, "wrong secret rejected") }

    var badSignature = packet("hello_ok")
    badSignature[DbpCodec.headerSize - 1] ^= 1
    let forgedResponse = badSignature
    let unauthenticated = RelayControlClient(secret: fixtureSecret, connectionFactory: {
        FakeDbpConnection(responseFrames: [forgedResponse])
    })
    do { _ = try await unauthenticated.health(); r.check(false, "forged health response rejected") }
    catch { r.check(error as? DroidBridgeError == .relayAuthenticationFailed,
                    "authentication failure before deadline preserves its type") }

    let malformed = RelayControlClient(secret: fixtureSecret, connectionFactory: {
        FakeDbpConnection(responseFrames: [Data(repeating: 0, count: 64)])
    })
    do { _ = try await malformed.health(); r.check(false, "malformed health header rejected") }
    catch {
        if case DroidBridgeError.relayProtocol = error {
            r.check(true, "protocol failure before deadline preserves its type")
        } else { r.check(false, "protocol failure must not be relabeled as a timeout") }
    }

    // timeout actively closes a stalled transport so structured concurrency
    // cannot wait forever for an uncooperative receive continuation.
    let hanging = HangingDbpConnection()
    let timeoutClient = RelayControlClient(
        secret: fixtureSecret,
        connectionFactory: { hanging },
        now: { 1_700_000_000 }
    )
    do {
        _ = try await timeoutClient.health(timeout: .milliseconds(20))
        r.check(false, "stalled health should time out")
    } catch {
        r.check(hanging.wasClosed, "health timeout closes stalled transport")
        r.check(error as? DroidBridgeError == .relayTimedOut,
                "health deadline reports timeout, not the EOF caused by cancelling its receive")
    }

    // --- RelayPreparer rollback ---
    let adb = StubAdb(failRelayForward: true)
    let preparer = RelayPreparer(adb: adb, healthClient: StubHealth(result: .success(RelayHealth(status: .ready, activeSessions: 0, maximumSessions: 128, uploadedBytes: 0, downloadedBytes: 0, carrierName: "C"))))
    do {
        _ = try await preparer.prepare(device: AdbDevice(serial: "R1", state: .authorized), secret: Data(count: 32))
        r.check(false, "relay forward failure throws")
    } catch { r.check(await adb.removed == [RelayPreparer.pairingPort], "rolls back pairing forward when relay forward fails") }

    // health-unavailable path opens the app and rolls back both forwards
    let adb2 = StubAdb()
    let preparer2 = RelayPreparer(adb: adb2, healthClient: StubHealth(result: .failure(.relayTimedOut)))
    do { _ = try await preparer2.prepare(device: AdbDevice(serial: "R1", state: .authorized), secret: Data(count: 32)); r.check(false, "health failure throws") }
    catch {
        let removed = await adb2.removed.sorted()
        let started = await adb2.didStart
        r.check(removed == [RelayPreparer.relayPort, RelayPreparer.pairingPort].sorted() && started, "opens app and rolls back on health failure")
    }

    // Changing a USB port is a transport change; only a verified peer can update that location.
    let oldConfig = try! TunnelRuntimeConfiguration(deviceSerial: "aoa:0-1", relayHost: "127.0.0.1",
        relayPort: 27183, pairedPeerId: "paired-phone", keychainAccount: "paired-phone", maximumFlows: 128)
    let configStore = PortConfigurationStore(oldConfig)
    let newPort = AdbDevice(serial: "aoa:0-2", state: .authorized)
    let portAdb = StubAdb()
    let rejected = RelayPreparer(adb: portAdb, healthClient: StubHealth(result: .failure(.relayTimedOut)))
    do {
        _ = try await rejected.preparePaired(device: newPort, secret: Data(count: 32), configuration: oldConfig, store: configStore)
        r.check(false, "unverified USB port must fail")
    } catch {
        r.check(configStore.read() == oldConfig, "failed authentication preserves previous USB location and pairing")
    }
    let accepted = RelayPreparer(adb: StubAdb(), healthClient: StubHealth(result: .success(RelayHealth(
        status: .ready, activeSessions: 0, maximumSessions: 128, uploadedBytes: 0, downloadedBytes: 0, carrierName: "C"))))
    do {
        _ = try await accepted.preparePaired(device: newPort, secret: Data(count: 32), configuration: oldConfig, store: configStore)
        let updated = configStore.read()
        r.check(updated?.deviceSerial == "aoa:0-2" && updated?.keychainAccount == "paired-phone"
            && updated?.pairedPeerId == "paired-phone", "authenticated USB port change retains the original pairing")
    } catch { r.check(false, "authenticated USB port update: \(error)") }
    r.check(!oldConfig.acceptsTransportCandidate(serial: "other-adb-device"), "USB port fallback cannot select an unrelated transport")

    r.finish("relay")
}

private final class PortConfigurationStore: RuntimeConfigurationStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: TunnelRuntimeConfiguration?
    init(_ value: TunnelRuntimeConfiguration) { self.value = value }
    func read() -> TunnelRuntimeConfiguration? { lock.withLock { value } }
    func write(_ configuration: TunnelRuntimeConfiguration) { lock.withLock { value = configuration } }
    func delete() { lock.withLock { value = nil } }
}
