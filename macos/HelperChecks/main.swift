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

do {
    try testRouteRestoreRetryDoesNotRedeleteUtun()
    try testPersistedRouteRecoveryIsIdempotent()
    try testRecoveryStateStoreRoundTrip()
    try testPfReleaseFailureRetainsTokenForRetry()
    try testPendingPfJournalCanBeRecovered()
    print("helper checks: 5 passed, 0 failed")
} catch {
    FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
