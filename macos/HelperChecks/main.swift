import DroidBridgeShared
import Foundation

private struct ExpectedCommand {
    let executable: String
    let arguments: [String]
    let result: HelperCommandResult
}

private final class ScriptedRunner {
    private(set) var calls: [(String, [String])] = []
    private var commands: [ExpectedCommand]

    init(_ commands: [ExpectedCommand]) {
        self.commands = commands
    }

    func run(_ executable: URL, _ arguments: [String], _ input: Data?) throws -> HelperCommandResult {
        precondition(!commands.isEmpty, "unexpected command: \(executable.path) \(arguments)")
        let expected = commands.removeFirst()
        precondition(executable.path == expected.executable, "unexpected executable: \(executable.path)")
        precondition(arguments == expected.arguments, "unexpected arguments: \(arguments)")
        calls.append((executable.path, arguments))
        return expected.result
    }

    var isEmpty: Bool { commands.isEmpty }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }

    var current: Int { lock.withLock { value } }
}

private actor StartupOrderRecorder {
    private var events: [String] = []

    func append(_ event: String) { events.append(event) }
    var recorded: [String] { events }
}

private func result(_ status: Int32 = 0, _ output: String = "") -> HelperCommandResult {
    HelperCommandResult(
        status: status,
        standardOutput: Data(output.utf8),
        standardError: Data()
    )
}

private func command(_ arguments: [String], _ result: HelperCommandResult) -> ExpectedCommand {
    ExpectedCommand(executable: "/sbin/route", arguments: arguments, result: result)
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private func testRouteRestoreRetryDoesNotRedeleteUtun() throws {
    let gateway = "192.0.2.1"
    let runner = ScriptedRunner([
        command(["-n", "get", "default"], result(0, "gateway: \(gateway)\ninterface: en0\n")),
        command(["-n", "delete", "-inet", "default", gateway], result()),
        command(["-n", "add", "-inet", "default", "-interface", "utun7"], result()),
        command(["-n", "delete", "-inet", "default", "-interface", "utun7"], result()),
        command(["-n", "add", "-inet", "default", gateway], result(1, "temporary failure")),
        command(["-n", "get", "default"], result(1, "not in table")),
        command(["-n", "add", "-inet", "default", gateway], result()),
        command(["-n", "get", "default"], result(0, "gateway: \(gateway)\ninterface: en0\n")),
    ])
    let controller = RouteController(run: runner.run)
    try controller.setDefault(utun: "utun7")
    do {
        try controller.restore()
        check(false, "the first restore should fail")
    } catch {}
    try controller.restore()
    check(!controller.isConfigured, "the second restore should clear recovery state")
    check(runner.isEmpty, "every scripted route command should be consumed")
    let utunDeletes = runner.calls.filter {
        $0.1 == ["-n", "delete", "-inet", "default", "-interface", "utun7"]
    }
    check(utunDeletes.count == 1, "a retry must not delete the utun route twice")
}

private func testPersistedRouteRecoveryIsIdempotent() throws {
    let gateway = "198.51.100.1"
    let runner = ScriptedRunner([
        command(["-n", "delete", "-inet", "default", "-interface", "utun4"], result(1, "not in table")),
        command(["-n", "get", "default"], result(0, "gateway: \(gateway)\ninterface: en0\n")),
        command(["-n", "add", "-inet", "default", gateway], result(1, "file exists")),
        command(["-n", "get", "default"], result(0, "gateway: \(gateway)\ninterface: en0\n")),
    ])
    let controller = RouteController(run: runner.run)
    try controller.adoptRecoveryState(gateway: gateway, utun: "utun4")
    try controller.restore()
    check(!controller.isConfigured, "already-restored routes should be accepted")
    check(runner.isEmpty, "every persisted recovery command should be consumed")
}

private func testRecoveryStateStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidbridge-helper-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("recovery.json")
    let store = HelperRecoveryStateStore(url: url)
    let expected = HelperRecoveryState(
        gateway: "203.0.113.1",
        utun: "utun9",
        pfEnableToken: "12345"
    )
    try store.save(expected)
    let loaded = try store.load()
    check(loaded == expected, "recovery state should round-trip")
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
    check(mode?.intValue == 0o600, "recovery state permissions should be 0600")
    try store.remove()
    let removed = try store.load()
    check(removed == nil, "recovery state should be removable")
}

private func testPfReleaseFailureRetainsTokenForRetry() throws {
    let runner = ScriptedRunner([
        ExpectedCommand(
            executable: "/sbin/pfctl",
            arguments: ["-a", PfController.anchorName, "-F", "rules"],
            result: result()
        ),
        ExpectedCommand(
            executable: "/sbin/pfctl",
            arguments: ["-X", "7654"],
            result: result(1, "temporary PF failure")
        ),
        ExpectedCommand(
            executable: "/sbin/pfctl",
            arguments: ["-a", PfController.anchorName, "-F", "rules"],
            result: result()
        ),
        ExpectedCommand(
            executable: "/sbin/pfctl",
            arguments: ["-X", "7654"],
            result: result()
        ),
    ])
    let controller = PfController(run: runner.run)
    try controller.adoptRecoveryToken("7654")
    do {
        try controller.disable()
        check(false, "the first PF release should fail")
    } catch {}
    check(controller.isEnabled, "a failed PF release must retain its token")
    try controller.disable()
    check(!controller.isEnabled, "a successful retry should clear its token")
    check(runner.isEmpty, "every PF recovery command should be consumed")
}

private func testPendingPfJournalCanBeRecovered() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidbridge-helper-pending-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = HelperRecoveryStateStore(url: directory.appendingPathComponent("recovery.json"))
    let pending = HelperRecoveryState(gateway: "192.0.2.1", utun: "utun3", pfEnableToken: nil)
    try store.save(pending)
    let loaded = try store.load()
    check(loaded == pending, "a pre-token PF journal should round-trip")

    let runner = ScriptedRunner([
        ExpectedCommand(
            executable: "/sbin/pfctl",
            arguments: ["-a", PfController.anchorName, "-F", "rules"],
            result: result()
        ),
    ])
    try PfController(run: runner.run).clearAnchorRules()
    check(runner.isEmpty, "pending PF recovery should flush the anchor")
}

private func testInstallerMachServiceKeyPathIsAcceptedByPlutil() throws {
    let plist = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("macos/Helper/io.droidbridge.helper.plist")
    let output = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
    process.arguments = [
        "-extract", ManualHelperInstaller.machServicePlistKeyPath,
        "raw", "-o", "-", plist.path,
    ]
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    check(process.terminationStatus == 0 && text == "true",
          "the installer Mach service key path must resolve to true")
}

private func testInstallerDetectsStaleInstalledHelper() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidbridge-installer-digest-\(UUID().uuidString)", isDirectory: true)
    let embeddedDirectory = directory
        .appendingPathComponent("DroidBridge.app/Contents/Library/LaunchDaemons", isDirectory: true)
    try FileManager.default.createDirectory(at: embeddedDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bundle = directory.appendingPathComponent("DroidBridge.app", isDirectory: true)
    let embedded = embeddedDirectory.appendingPathComponent("DroidBridgeHelper")
    let installed = directory.appendingPathComponent("io.droidbridge.helper")
    try Data("new helper".utf8).write(to: embedded)
    try Data("old helper".utf8).write(to: installed)

    let installer = ManualHelperInstaller(bundleURL: bundle)
    check(!installer.installedHelperMatchesEmbedded(at: installed),
          "different helper binaries must require an update even when versions match")

    try Data("new helper".utf8).write(to: installed)
    check(installer.installedHelperMatchesEmbedded(at: installed),
          "identical helper binaries should not require an update")
}

private func testEnginePollTimerRunsAndStops() {
    let queue = DispatchQueue(label: "io.droidbridge.checks.engine-poll")
    let timer = EnginePollTimer(queue: queue, interval: .milliseconds(20))
    let counter = PollCounter()
    let reachedThree = DispatchSemaphore(value: 0)

    timer.start {
        if counter.increment() == 3 { reachedThree.signal() }
    }
    check(reachedThree.wait(timeout: .now() + .seconds(1)) == .success,
          "the engine timer must poll repeatedly while running")

    timer.stop()
    queue.sync {}
    let stoppedAt = counter.current
    Thread.sleep(forTimeInterval: 0.1)
    queue.sync {}
    check(counter.current == stoppedAt, "the engine timer must stop polling after cancellation")
}

@MainActor
private func testTunnelStartupPreflightsBeforeRouteMutation() async {
    let success = StartupOrderRecorder()
    let sequence = TunnelStartupSequence(
        installHelper: { await success.append("install") },
        prepareRelay: { await success.append("prepare") },
        startTunnel: { await success.append("start") }
    )
    do {
        try await sequence.run()
        let events = await success.recorded
        check(events == ["install", "prepare", "start"],
              "startup must revalidate the relay immediately before route mutation")
    } catch {
        check(false, "successful startup sequence should not throw")
    }

    let failed = StartupOrderRecorder()
    let rejected = TunnelStartupSequence(
        installHelper: { await failed.append("install") },
        prepareRelay: {
            await failed.append("prepare")
            throw DroidBridgeError.relayTimedOut
        },
        startTunnel: { await failed.append("start") }
    )
    do {
        try await rejected.run()
        check(false, "failed relay preflight must reject startup")
    } catch {
        let events = await failed.recorded
        check(events == ["install", "prepare"],
              "route mutation must not run after relay preflight failure")
    }
}

private func networksetup(_ arguments: [String], _ result: HelperCommandResult) -> ExpectedCommand {
    ExpectedCommand(executable: "/usr/sbin/networksetup", arguments: arguments, result: result)
}

private func resolverFlush() -> [ExpectedCommand] {
    [
        ExpectedCommand(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"], result: result()),
        ExpectedCommand(executable: "/usr/bin/killall", arguments: ["-HUP", "mDNSResponder"], result: result()),
    ]
}

private let dnsServiceOrder = """
An asterisk (*) denotes that a network service is disabled.
(1) USB 10/100/1000 LAN
(Hardware Port: USB 10/100/1000 LAN, Device: en7)

(2) Wi-Fi
(Hardware Port: Wi-Fi, Device: en0)

(3) Tailscale
(Hardware Port: io.tailscale.ipn.macos, Device: )
"""

/// The tunnel must send the system resolver into 198.18.0.1 and, on stop, put
/// back exactly what the user had — including a manual list, which a naive
/// "reset to DHCP" would erase.
private func testDnsApplyAndRestorePreserveManualServers() throws {
    let runner = ScriptedRunner([
        networksetup(["-listnetworkserviceorder"], result(0, dnsServiceOrder)),
        networksetup(["-getdnsservers", "USB 10/100/1000 LAN"], result(0, "8.8.8.8\n")),
        networksetup(["-getdnsservers", "Wi-Fi"], result(0, "There aren't any DNS Servers set on Wi-Fi.\n")),
        networksetup(["-setdnsservers", "USB 10/100/1000 LAN", "198.18.0.1"], result()),
        networksetup(["-setdnsservers", "Wi-Fi", "198.18.0.1"], result()),
    ] + resolverFlush() + [
        networksetup(["-setdnsservers", "USB 10/100/1000 LAN", "8.8.8.8"], result()),
        networksetup(["-setdnsservers", "Wi-Fi", "Empty"], result()),
    ] + resolverFlush())
    let controller = DnsController(run: runner.run)
    let originals = try controller.capture()
    check(originals == ["USB 10/100/1000 LAN": ["8.8.8.8"], "Wi-Fi": []],
          "capture should record manual and DHCP-provided DNS per service")
    try controller.apply(originals)
    check(controller.isConfigured, "applied DNS must be tracked for restore")
    try controller.restore()
    check(!controller.isConfigured, "a successful restore clears the tracked state")
    check(runner.isEmpty, "every scripted DNS command should be consumed")
}

/// An unreadable service must stop the start before anything is changed:
/// guessing "DHCP" would later restore Empty over a manual setting.
private func testDnsCaptureRefusesUnreadableService() throws {
    let runner = ScriptedRunner([
        networksetup(["-listnetworkserviceorder"], result(0, dnsServiceOrder)),
        networksetup(["-getdnsservers", "USB 10/100/1000 LAN"], result(0, "** Error: The parameters were not valid.\n")),
    ])
    let controller = DnsController(run: runner.run)
    do {
        _ = try controller.capture()
        check(false, "capture should reject an unrecognized -getdnsservers answer")
    } catch {}
    check(!controller.isConfigured, "a failed capture must not claim configured DNS")
    check(runner.isEmpty, "no DNS setting may be changed after a failed capture")
}

/// A failed restore keeps the originals so Stop can be retried, like PF and routes.
private func testDnsRestoreFailureRetainsStateForRetry() throws {
    let runner = ScriptedRunner([
        networksetup(["-setdnsservers", "Wi-Fi", "Empty"], result(4, "** Error\n")),
    ] + resolverFlush() + [
        networksetup(["-setdnsservers", "Wi-Fi", "Empty"], result()),
    ] + resolverFlush())
    let controller = DnsController(run: runner.run)
    try controller.adoptRecoveryState(["Wi-Fi": []])
    do {
        try controller.restore()
        check(false, "the first DNS restore should fail")
    } catch {}
    check(controller.isConfigured, "a failed DNS restore must retain its originals")
    try controller.restore()
    check(!controller.isConfigured, "a successful retry clears the originals")
    check(runner.isEmpty, "every DNS retry command should be consumed")
}

private func testDnsRecoveryRejectsInvalidJournal() {
    let controller = DnsController(run: { _, _, _ in result() })
    do {
        try controller.adoptRecoveryState(["Wi-Fi": ["8.8.8.8; rm -rf /"]])
        check(false, "a tampered DNS journal entry must be rejected")
    } catch {}
    check(!controller.isConfigured, "a rejected journal must not be adopted")
}

private func testRecoveryStateCarriesDnsAndReadsOldJournals() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidbridge-helper-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("recovery.json")
    let store = HelperRecoveryStateStore(url: url)
    let expected = HelperRecoveryState(
        gateway: "203.0.113.1", utun: "utun9", pfEnableToken: "7",
        dnsServers: ["Wi-Fi": [], "USB 10/100/1000 LAN": ["8.8.8.8"]]
    )
    try store.save(expected)
    let loaded = try store.load()
    check(loaded == expected, "a journal with DNS originals should round-trip")

    // A journal written by a helper that predates DNS handling must still load,
    // or an upgrade would strand a retained fail-closed state.
    try Data(#"{"gateway":"203.0.113.1","utun":"utun9","pfEnableToken":"7"}"#.utf8).write(to: url)
    let legacy = try store.load()
    check(legacy != nil && legacy?.dnsServers == nil, "a pre-DNS journal should load with no DNS originals")
}

do {
    try testRouteRestoreRetryDoesNotRedeleteUtun()
    try testPersistedRouteRecoveryIsIdempotent()
    try testRecoveryStateStoreRoundTrip()
    try testPfReleaseFailureRetainsTokenForRetry()
    try testPendingPfJournalCanBeRecovered()
    try testInstallerMachServiceKeyPathIsAcceptedByPlutil()
    try testInstallerDetectsStaleInstalledHelper()
    testEnginePollTimerRunsAndStops()
    await testTunnelStartupPreflightsBeforeRouteMutation()
    try testDnsApplyAndRestorePreserveManualServers()
    try testDnsCaptureRefusesUnreadableService()
    try testDnsRestoreFailureRetainsStateForRetry()
    testDnsRecoveryRejectsInvalidJournal()
    try testRecoveryStateCarriesDnsAndReadsOldJournals()
    print("helper checks: 14 passed, 0 failed")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
