import Foundation

/// Serializes access to adb, applies a per-command timeout, and tracks only the forwards it created.
public actor AdbClient {
    private let executable: URL
    private let runner: ProcessRunning
    private let defaultTimeout: Duration
    private var ownedForwards: Set<UInt16> = []

    public init(executable: URL, runner: ProcessRunning, defaultTimeout: Duration = .seconds(5)) {
        self.executable = executable
        self.runner = runner
        self.defaultTimeout = defaultTimeout
    }

    public func devices(timeout: Duration? = nil) async throws -> [AdbDevice] {
        let result = try await run(["devices", "-l"], timeout: timeout)
        try ensureSuccess(result)
        return AdbClient.parseDevices(result.stdoutText)
    }

    /// Creates tcp:hostPort -> tcp:devicePort, refusing if another owner already holds that host port.
    public func forward(serial: String, hostPort: UInt16, devicePort: UInt16, timeout: Duration? = nil) async throws {
        let list = try await run(["-s", serial, "forward", "--list"], timeout: timeout)
        try ensureSuccess(list)
        if AdbClient.forwardConflicts(list.stdoutText, serial: serial, hostPort: hostPort, devicePort: devicePort) {
            throw DroidBridgeError.forwardConflict(port: hostPort)
        }
        let result = try await run(["-s", serial, "forward", "tcp:\(hostPort)", "tcp:\(devicePort)"], timeout: timeout)
        try ensureSuccess(result)
        ownedForwards.insert(hostPort)
    }

    public func removeForward(serial: String, hostPort: UInt16, timeout: Duration? = nil) async throws {
        guard ownedForwards.contains(hostPort) else { return } // only remove forwards we created
        let result = try await run(["-s", serial, "forward", "--remove", "tcp:\(hostPort)"], timeout: timeout)
        try ensureSuccess(result)
        ownedForwards.remove(hostPort)
    }

    public func removeOwnedForwards(serial: String) async {
        for port in ownedForwards { _ = try? await removeForward(serial: serial, hostPort: port) }
    }

    public func startActivity(serial: String, component: String, timeout: Duration? = nil) async throws {
        let result = try await run(["-s", serial, "shell", "am", "start", "-n", component], timeout: timeout)
        try ensureSuccess(result)
    }

    public func packagePath(serial: String, package: String, timeout: Duration? = nil) async throws -> String? {
        let result = try await run(["-s", serial, "shell", "pm", "path", package], timeout: timeout)
        guard result.exitCode == 0 else { return nil }
        let line = result.stdoutText.split(separator: "\n").first.map(String.init) ?? ""
        return line.hasPrefix("package:") ? String(line.dropFirst("package:".count)) : nil
    }

    public var ownedForwardPorts: Set<UInt16> { ownedForwards }

    // MARK: - internals

    private func run(_ arguments: [String], timeout: Duration?) async throws -> ProcessResult {
        let deadline = timeout ?? defaultTimeout
        return try await withThrowingTaskGroup(of: ProcessResult.self) { group in
            let exe = executable
            let runner = runner
            group.addTask { try await runner.run(executable: exe, arguments: arguments, environment: [:]) }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw DroidBridgeError.adbTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw DroidBridgeError.adbTimedOut }
            return first
        }
    }

    private func ensureSuccess(_ result: ProcessResult) throws {
        guard result.exitCode == 0 else {
            throw DroidBridgeError.adbCommandFailed(exitCode: result.exitCode,
                                                    message: String(result.stderrText.prefix(200)))
        }
    }

    // MARK: - parsing (pure, testable)

    public static func parseDevices(_ output: String) -> [AdbDevice] {
        var devices: [AdbDevice] = []
        var seen: Set<String> = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("List of devices attached") || line.hasPrefix("* daemon") { continue }
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 2 else { continue }
            let serial = fields[0]
            if seen.contains(serial) { continue }
            seen.insert(serial)
            let state: AdbDevice.State
            switch fields[1] {
            case "device": state = .authorized
            case "unauthorized": state = .unauthorized
            case "offline": state = .offline
            default: state = .unknown
            }
            var model: String?
            var transportId: String?
            for field in fields.dropFirst(2) {
                if field.hasPrefix("model:") { model = String(field.dropFirst("model:".count)) }
                if field.hasPrefix("transport_id:") { transportId = String(field.dropFirst("transport_id:".count)) }
            }
            devices.append(AdbDevice(serial: serial, state: state, model: model, transportId: transportId))
        }
        return devices
    }

    public static func forwardConflicts(_ listOutput: String, serial: String, hostPort: UInt16, devicePort: UInt16) -> Bool {
        // `adb forward --list` lines: "SERIAL tcp:HOST tcp:DEVICE". A different mapping on the same host port conflicts.
        for line in listOutput.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count >= 3, fields[1] == "tcp:\(hostPort)" else { continue }
            if fields[2] != "tcp:\(devicePort)" { return true }
        }
        return false
    }
}
