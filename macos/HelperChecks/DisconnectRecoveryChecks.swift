import Darwin
import DroidBridgeShared
import Foundation

private func requireRecovery(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

func runDisconnectRecoveryChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = HelperRecoveryStateStore(url: directory.appendingPathComponent("stop.json"))
    let stop = HelperStopCoordinator(store: store, timeout: 0.15, restart: { preconditionFailure("completed stop restarted helper") })
    let done = DispatchSemaphore(value: 0)
    stop.request(work: {
        requireRecovery(store.hasPersistedState, "Stop intent must exist before waiting on engine")
    }, reply: { success in
        requireRecovery(success, "normal recovery succeeds")
        done.signal()
    })
    requireRecovery(done.wait(timeout: .now() + 2) == .success, "normal Stop returns")
    requireRecovery(!stop.isPending && !store.hasPersistedState, "success clears intent")

    let failed = DispatchSemaphore(value: 0)
    stop.request(work: { throw NSError(domain: "recovery", code: 1) }, reply: { success in
        requireRecovery(!success, "failed verification must be reported")
        failed.signal()
    })
    requireRecovery(failed.wait(timeout: .now() + 2) == .success, "failure returns")
    requireRecovery(stop.isPending && store.hasPersistedState, "failure preserves explicit intent")
    let restarted = HelperStopCoordinator(store: store)
    var resumed = false
    try restarted.resumeIfRequested { resumed = true }
    requireRecovery(resumed && !restarted.isPending, "new process resumes explicit Stop")
    try restarted.resumeIfRequested { preconditionFailure("no intent must not restore network") }

    // Actual child process termination: no root privileges or real network mutations.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    child.arguments = ["--check-blocked-stop", directory.path]
    try child.run()
    child.waitUntilExit()
    requireRecovery(child.terminationStatus == 75, "watchdog must terminate blocked process")
    let persisted = HelperRecoveryStateStore(url: directory.appendingPathComponent("blocked.json"))
    requireRecovery(persisted.hasPersistedState, "killed engine leaves explicit intent for restart")
    let commandChild = Process()
    commandChild.executableURL = child.executableURL
    commandChild.arguments = ["--check-command-stop", directory.path]
    try commandChild.run()
    commandChild.waitUntilExit()
    requireRecovery(commandChild.terminationStatus == 75, "command-stop watchdog exits")
    let commandPID = Int32(try String(contentsOf: directory.appendingPathComponent("command.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    Thread.sleep(forTimeInterval: 0.1)
    let orphaned = kill(commandPID, 0) == 0
    if orphaned { kill(commandPID, SIGKILL) }
    requireRecovery(!orphaned, "watchdog must not leave a network command running after exit")
    let replacement = HelperStopCoordinator(store: persisted)
    try replacement.resumeIfRequested {}
    requireRecovery(!persisted.hasPersistedState, "replacement completes recovery")

    let start = Date()
    let command = try HelperCommandRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.1)
    requireRecovery(command.status != 0 && Date().timeIntervalSince(start) < 2, "stalled command has a deadline")
    try checkRecoveryVerifier()
}

func runBlockedStopChildIfRequested() {
    guard CommandLine.arguments.count == 3,
          ["--check-blocked-stop", "--check-command-stop"].contains(CommandLine.arguments[1]) else { return }
    if CommandLine.arguments[1] == "--check-command-stop" {
        let path = URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("command.pid").path
        DispatchQueue.global().async {
            _ = try? HelperCommandRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "echo $$ > \"$1\"; exec /bin/sleep 30", "fixture", path], timeout: 30)
        }
        let limit = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: path) && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    }
    let store = HelperRecoveryStateStore(url: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("blocked.json"))
    let stop = HelperStopCoordinator(store: store, timeout: 0.15)
    let engineLock = NSLock()
    engineLock.lock()
    stop.request(work: { engineLock.lock() }, reply: { _ in exit(99) })
    // Simulate an unresponsive lifecycle/engine queue. The independent watchdog must win.
    Thread.sleep(forTimeInterval: 3)
    exit(98)
}

private func checkRecoveryVerifier() throws {
    func runner(stale: String?) -> HelperCommandExecuting {
        { executable, arguments, input in
            let script = String(decoding: input ?? Data(), as: UTF8.self)
            var output = ""
            if executable.lastPathComponent == "scutil" {
                if arguments == ["--dns"] { output = stale == "dns" ? "nameserver[0] : 198.18.0.1\n" : "nameserver[0] : 192.168.1.1\n" }
                else if script.contains("/Service/") { output = stale == "service" ? "<dictionary> {}" : "No such key\n" }
                else { output = "PrimaryInterface : en0\n" }
            } else if executable.lastPathComponent == "route" {
                output = stale == "route" ? "gateway: 198.18.0.1\ninterface: utun9\n" : "gateway: 192.168.1.1\ninterface: en0\n"
            } else if executable.lastPathComponent == "pfctl" {
                output = stale == "pf" ? "block drop out quick on en0 all\n" : ""
            }
            return HelperCommandResult(status: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
    }
    try NetworkRecoveryVerifier(run: runner(stale: nil), attempts: 1, interval: 0).verify(utun: "utun9")
    for stale in ["service", "dns", "route", "pf"] {
        do {
            try NetworkRecoveryVerifier(run: runner(stale: stale), attempts: 1, interval: 0).verify(utun: "utun9")
            preconditionFailure("stale \(stale) must not be reported restored")
        } catch {}
    }
}

func runHelperStopRetryChecks() async throws {
    var attempts = 0
    try await HelperStopRetry.run(delay: .zero) {
        attempts += 1
        if attempts < 3 { throw HelperClientError.unavailable }
    }
    requireRecovery(attempts == 3, "XPC interruptions during daemon replacement are retried")
    attempts = 0
    do {
        try await HelperStopRetry.run(delay: .zero) {
            attempts += 1
            throw HelperClientError.rejected("restoration failed")
        }
        preconditionFailure("restoration rejection is reported")
    } catch HelperClientError.rejected {}
    requireRecovery(attempts == 1, "definite restoration failure is not silently retried")
    let start = ContinuousClock.now
    do {
        try await HelperStopRetry.run(timeout: .milliseconds(30), delay: .milliseconds(5)) {
            throw HelperClientError.unavailable
        }
        preconditionFailure("unavailable daemon must not wait forever")
    } catch HelperClientError.timedOut {}
    requireRecovery(start.duration(to: .now) < .seconds(1), "client recovery wait is bounded")
}

func runHelperRecoveryIntegrationChecks() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let journal = HelperRecoveryStateStore(url: directory.appendingPathComponent("journal.json"))
    let intent = HelperRecoveryStateStore(url: directory.appendingPathComponent("stop.json"))
    final class SystemState: @unchecked Sendable {
        var published = true
        var rules = true
        var failDNS = true
        var releases = 0
        var commands = 0
        var routeInterface = "en0"
        var alreadyReleased = false
        func run(_ url: URL, _ args: [String], _ input: Data?) -> HelperCommandResult {
            commands += 1
            var output = ""
            let script = String(decoding: input ?? Data(), as: UTF8.self)
            if url.lastPathComponent == "scutil" {
                if script.hasPrefix("remove ") { published = false }
                else if script.contains("/Service/") { output = published ? "<dictionary> {}" : "No such key" }
                else if args == ["--dns"] { output = "nameserver[0] : " + (failDNS ? "198.18.0.1" : "192.168.1.1") }
                else { output = "PrimaryInterface : " + routeInterface }
            } else if url.lastPathComponent == "route" { output = "interface: " + routeInterface + "\ngateway: 192.168.1.1" }
            else if url.lastPathComponent == "pfctl" {
                if args.contains("-F") { rules = false }
                else if args.first == "-X" {
                    releases += 1
                    if alreadyReleased { return HelperCommandResult(status: 1, standardOutput: Data(), standardError: Data("token absent".utf8)) }
                }
                else if args == ["-s", "References"] { output = "No pf starter references held" }
                else if args.contains("-s") { output = rules ? "block all" : "" }
            }
            return HelperCommandResult(status: 0, standardOutput: Data(output.utf8), standardError: Data())
        }
    }
    let system = SystemState()
    try journal.save(HelperRecoveryState(utun: "utun99", pfEnableToken: "1234"))
    func service() -> HelperService {
        HelperService(pfController: PfController(run: system.run),
                      networkService: NetworkServicePublisher(run: system.run), recoveryStore: journal,
                      stopCoordinator: HelperStopCoordinator(store: intent),
                      recoveryVerifier: NetworkRecoveryVerifier(run: system.run, attempts: 1, interval: 0))
    }
    let original = service()
    try original.reconcilePersistedState()
    original.resumePendingStop()
    requireRecovery(system.commands == 0, "restart without explicit Stop must retain fail-closed network")
    let done = DispatchSemaphore(value: 0)
    original.stopTunnel { ok in requireRecovery(!ok, "stale DNS must fail recovery"); done.signal() }
    requireRecovery(done.wait(timeout: .now() + 2) == .success, "Stop failure replies")
    requireRecovery(intent.hasPersistedState && journal.hasPersistedState && system.releases == 0,
                    "retain intent and PF while configd DNS is stale")
    system.failDNS = false
    system.routeInterface = "utun99" // Another VPN reused the old, now closed interface index.
    let rebooted = service()
    try rebooted.reconcilePersistedState()
    rebooted.resumePendingStop()
    requireRecovery(!intent.hasPersistedState && !journal.hasPersistedState && system.releases == 1 && !system.rules,
                    "new helper resumes Stop and restores only owned rules/token")
    rebooted.status { data in
        let snapshot = try! JSONDecoder().decode(TunnelMetricsSnapshot.self, from: data)
        requireRecovery(!snapshot.tunnelActive && snapshot.runtimeStatus == .stopped, "verified Stop reaches stopped status")
    }
    // Model death after -X succeeds but before the token-free journal rename.
    try journal.save(HelperRecoveryState(utun: "utun99", pfEnableToken: "1234"))
    try intent.save(HelperRecoveryState(utun: "explicit-stop", pfEnableToken: nil))
    system.alreadyReleased = true
    let afterReleaseCrash = service()
    try afterReleaseCrash.reconcilePersistedState()
    afterReleaseCrash.resumePendingStop()
    requireRecovery(!intent.hasPersistedState && !journal.hasPersistedState,
                    "crash after PF release cannot strand explicit recovery on an absent token")
    let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "macos/Helper/io.droidbridge.helper.plist")), format: nil) as! [String: Any]
    let keepAlive = plist["KeepAlive"] as? [String: Bool]
    requireRecovery(keepAlive?["SuccessfulExit"] == false, "launchd resumes abnormal-exit recovery even when host closes")
}

func runReleasedPFReferenceChecks() throws {
    let header = "TOKENS:\nPID      Process Name                 TOKEN                    TIMESTAMP\n"
    for (listing, status, shouldSucceed) in [
        ("No pf starter references held\n", Int32(0), true),
        (header + "10       Other VPN                    9999                     0 days 00:01:02\n", 0, true),
        (header + "10       DroidBridge Helper           7654                     0 days 00:01:02\n", 0, false),
        ("No pf_enabled references\n", 1, false),
        ("unexpected output", 0, false),
    ] {
        let controller = PfController(run: { _, args, _ in
            if args.first == "-X" { return HelperCommandResult(status: 1, standardOutput: Data(), standardError: Data("token not found".utf8)) }
            if args == ["-s", "References"] { return HelperCommandResult(status: status, standardOutput: Data(listing.utf8), standardError: Data()) }
            return HelperCommandResult(status: 0, standardOutput: Data(), standardError: Data())
        })
        try controller.adoptRecoveryToken("7654")
        var succeeded = false
        do { try controller.disable(); succeeded = true } catch {}
        requireRecovery(succeeded == shouldSucceed, "released-token retry requires verified absence, even if another VPN holds PF")
        requireRecovery(controller.isEnabled != shouldSucceed, "unverified PF reference remains retryable")
    }
}
