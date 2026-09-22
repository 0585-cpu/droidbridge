import DroidBridgeShared
import Foundation

/// Stub runner returning a canned result; records the arguments it was asked to run.
final class StubProcessRunner: ProcessRunning, @unchecked Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    private let lock = NSLock()
    private(set) var invocations: [[String]] = []
    init(stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        lock.withLock { invocations.append(arguments) }
        return ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }
}

/// Never returns until cancelled; records that cancellation (i.e. termination) happened.
final class HangingProcessRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var terminated = false
    var wasTerminated: Bool { lock.withLock { terminated } }
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(3600))
            return ProcessResult(exitCode: 0, stdout: Data(), stderr: Data())
        } onCancel: {
            self.lock.withLock { self.terminated = true }
        }
    }
}

func runAdbChecks(_ r: CheckRunner) async {
    let output = """
    List of devices attached
    R58M123 device product:gts model:Galaxy_Tab transport_id:1
    ABC999 unauthorized usb:1-2 transport_id:2
    emulator-5554 offline transport_id:3
    """
    let client = AdbClient(executable: URL(fileURLWithPath: "/adb"), runner: StubProcessRunner(stdout: output))
    if let devices = try? await client.devices() {
        r.check(devices.map(\.state) == [.authorized, .unauthorized, .offline], "parses three device states")
        r.check(devices.first?.model == "Galaxy_Tab", "parses model")
        r.check(devices.first?.transportId == "1", "parses transport id")
    } else { r.check(false, "devices() succeeds") }

    // daemon noise, blanks, duplicate serials
    let noisy = "* daemon not running; starting now at tcp:5037\n* daemon started successfully\nList of devices attached\n\nR1 device\nR1 device\n"
    let parsed = AdbClient.parseDevices(noisy)
    r.check(parsed.count == 1 && parsed[0].serial == "R1", "dedups and skips daemon noise")

    // conflict detection
    r.check(AdbClient.forwardConflicts("R1 tcp:27183 tcp:99999", serial: "R1", hostPort: 27183, devicePort: 27183), "different mapping conflicts")
    r.check(!AdbClient.forwardConflicts("R1 tcp:27183 tcp:27183", serial: "R1", hostPort: 27183, devicePort: 27183), "same mapping is not a conflict")
    r.check(!AdbClient.forwardConflicts("", serial: "R1", hostPort: 27183, devicePort: 27183), "no forwards is not a conflict")

    // nonzero exit surfaces error
    let failing = AdbClient(executable: URL(fileURLWithPath: "/adb"), runner: StubProcessRunner(stderr: "adb: no devices", exitCode: 1))
    do { _ = try await failing.devices(); r.check(false, "nonzero exit throws") }
    catch { r.check(true, "nonzero exit throws") }

    // timeout terminates the hung process
    let hanging = HangingProcessRunner()
    let hangClient = AdbClient(executable: URL(fileURLWithPath: "/adb"), runner: hanging)
    do { _ = try await hangClient.devices(timeout: .milliseconds(20)); r.check(false, "timeout throws") }
    catch { r.check(true, "timeout throws") }
    try? await Task.sleep(for: .milliseconds(50))
    r.check(hanging.wasTerminated, "hung process is terminated on timeout")

    // only-created forwards are removed
    let fwRunner = StubProcessRunner(stdout: "")
    let fwClient = AdbClient(executable: URL(fileURLWithPath: "/adb"), runner: fwRunner)
    try? await fwClient.forward(serial: "R1", hostPort: 27183, devicePort: 27183)
    let owned = await fwClient.ownedForwardPorts
    r.check(owned == [27183], "records created forward")
    try? await fwClient.removeForward(serial: "R1", hostPort: 27184) // not owned -> no-op
    let stillOwned = await fwClient.ownedForwardPorts
    r.check(stillOwned == [27183], "does not remove forwards it did not create")

    // locator order
    let locator = AdbExecutableLocator(environment: ["ANDROID_HOME": "/sdk"], fileExists: { $0 == "/sdk/platform-tools/adb" })
    r.check((try? locator.locate())?.path == "/sdk/platform-tools/adb", "locator prefers ANDROID_HOME")
    let brew = AdbExecutableLocator(environment: [:], fileExists: { $0 == "/opt/homebrew/bin/adb" })
    r.check((try? brew.locate())?.path == "/opt/homebrew/bin/adb", "locator falls back to homebrew")
    let androidStudioDefault = AdbExecutableLocator(
        environment: ["HOME": "/Users/tester"],
        fileExists: { $0 == "/Users/tester/Library/Android/sdk/platform-tools/adb" }
    )
    r.check(
        (try? androidStudioDefault.locate())?.path == "/Users/tester/Library/Android/sdk/platform-tools/adb",
        "locator finds the default macOS Android SDK outside a shell environment"
    )
    let none = AdbExecutableLocator(environment: [:], fileExists: { _ in false })
    do { _ = try none.locate(); r.check(false, "missing adb throws") } catch { r.check(true, "missing adb throws") }

    r.finish("adb")
}
