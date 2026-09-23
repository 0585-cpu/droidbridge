import DroidBridgeShared
import Foundation

private struct ExpectedCommand {
    let executable: String
    let arguments: [String]
    let result: HelperCommandResult
    var input: String? = nil
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
        if let wanted = expected.input {
            let got = String(decoding: input ?? Data(), as: UTF8.self)
            precondition(got == wanted, "unexpected stdin for \(executable.path):\n\(got)")
        }
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

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

private func testRecoveryStateStoreRoundTrip() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("droidbridge-helper-checks-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("recovery.json")
    let store = HelperRecoveryStateStore(url: url)
    let expected = HelperRecoveryState(utun: "utun9", pfEnableToken: "12345")
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
    let pending = HelperRecoveryState(utun: "utun3", pfEnableToken: nil)
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


private func scutil(_ input: String, _ output: String = "") -> ExpectedCommand {
    ExpectedCommand(executable: "/usr/sbin/scutil", arguments: [], result: result(0, output), input: input)
}

private let primaryIsEn0 = "<dictionary> {\n  PrimaryInterface : en0\n}\n"
private let primaryIsUtun9 = "<dictionary> {\n  PrimaryInterface : utun9\n}\n"

/// Publishing is only done once configd has actually made the tunnel primary:
/// that, not scutil's exit status, is what keeps the default route on utun.
private func testNetworkServicePublishWaitsForConfigd() throws {
    let publish = TunnelNetworkService.publishScript(utun: "utun9")!
    let runner = ScriptedRunner([
        scutil(publish),
        scutil(TunnelNetworkService.primaryQuery, primaryIsEn0),
        scutil(TunnelNetworkService.primaryQuery, primaryIsUtun9),
        scutil(TunnelNetworkService.removeScript),
    ])
    let service = NetworkServicePublisher(run: runner.run, attempts: 5, pollInterval: 0)
    try service.publish(utun: "utun9")
    check(service.isPublished, "a confirmed publish is tracked")
    try service.withdraw()
    check(!service.isPublished, "withdraw clears the published state")
    check(runner.isEmpty, "every scutil step should be consumed")
}

/// scutil exits 0 even when configd refuses a write, so a rejection must be
/// read from its output; and a service configd never promotes must fail the
/// start while staying marked published, so the rollback withdraws it.
private func testNetworkServiceFailuresAreDetected() throws {
    let publish = TunnelNetworkService.publishScript(utun: "utun9")!
    let refused = ScriptedRunner([scutil(publish, "  Permission denied\n")])
    let refusedService = NetworkServicePublisher(run: refused.run, attempts: 3, pollInterval: 0)
    do {
        try refusedService.publish(utun: "utun9")
        check(false, "a refused scutil write must fail the publish")
    } catch {}
    check(refusedService.isPublished, "a failed publish stays marked so rollback withdraws it")

    let ignored = ScriptedRunner([
        scutil(publish),
        scutil(TunnelNetworkService.primaryQuery, primaryIsEn0),
        scutil(TunnelNetworkService.primaryQuery, primaryIsEn0),
        scutil(TunnelNetworkService.primaryQuery, primaryIsEn0),
    ])
    let ignoredService = NetworkServicePublisher(run: ignored.run, attempts: 3, pollInterval: 0)
    do {
        try ignoredService.publish(utun: "utun9")
        check(false, "a service configd never makes primary must fail the publish")
    } catch {}
    check(ignored.isEmpty, "the primary interface should be polled a bounded number of times")

    let unsafe = NetworkServicePublisher(run: { _, _, _ in
        check(false, "an unsafe interface name must be rejected before scutil runs")
        return result()
    })
    do {
        try unsafe.publish(utun: "utun9\nremove State:/Network/Global/IPv4")
        check(false, "an unsafe interface name must be rejected")
    } catch {}
    check(!unsafe.isPublished, "a rejected name publishes nothing")
}

/// Withdraw is also the crash-recovery path, run by a fresh helper that never
/// published anything itself, so absent keys must be accepted.
private func testNetworkServiceWithdrawIsIdempotent() throws {
    let runner = ScriptedRunner([
        scutil(TunnelNetworkService.removeScript, "  No such key\n  No such key\n"),
        scutil(TunnelNetworkService.removeScript, "  Permission denied\n"),
    ])
    let service = NetworkServicePublisher(run: runner.run)
    try service.withdraw()
    check(!service.isPublished, "withdrawing absent keys succeeds")
    do {
        try service.withdraw()
        check(false, "a refused removal must be reported")
    } catch {}
    check(runner.isEmpty, "both withdraw attempts should run scutil")
}

do {
    try testRecoveryStateStoreRoundTrip()
    try testPfReleaseFailureRetainsTokenForRetry()
    try testPendingPfJournalCanBeRecovered()
    try testInstallerMachServiceKeyPathIsAcceptedByPlutil()
    try testInstallerDetectsStaleInstalledHelper()
    testEnginePollTimerRunsAndStops()
    await testTunnelStartupPreflightsBeforeRouteMutation()
    try testNetworkServicePublishWaitsForConfigd()
    try testNetworkServiceFailuresAreDetected()
    try testNetworkServiceWithdrawIsIdempotent()
    print("helper checks: 10 passed, 0 failed")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
