import Foundation
import Darwin

struct HelperCommandResult {
    let status: Int32
    let standardOutput: Data
    let standardError: Data

    var outputText: String {
        String(decoding: standardOutput + standardError, as: UTF8.self)
    }
}
typealias HelperCommandExecuting = (_ executable: URL, _ arguments: [String], _ input: Data?) throws -> HelperCommandResult

enum HelperCommandRunner {
    private final class Commands: @unchecked Sendable {
        let lock = NSLock()
        var running: [Int32: Process] = [:]
    }
    private static let commands = Commands()

    static func exitForRecovery() -> Never {
        // Serialize with spawning: no old scutil/pfctl may outlive this process
        // and race the fresh helper's restoration or a later tunnel start.
        commands.lock.lock()
        for process in commands.running.values where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        _exit(75) // No waits/destructors on the independent watchdog.
    }

    static func run(
        executable: URL,
        arguments: [String],
        input: Data? = nil
    ) throws -> HelperCommandResult {
        try run(executable: executable, arguments: arguments, input: input, timeout: 3)
    }

    static func run(executable: URL, arguments: [String], input: Data? = nil,
                    timeout: TimeInterval) throws -> HelperCommandResult {
        // Private temporary files avoid pipe backpressure deadlocks and unbounded reads
        // if a child inherits a pipe. All shipped commands are direct system executables.
        func temporary() throws -> FileHandle {
            var path = Array((NSTemporaryDirectory() + "droidbridge-command.XXXXXX").utf8CString)
            let fd = mkstemp(&path)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            unlink(path)
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let output = try temporary(), errors = try temporary(), source = try temporary()
        defer { try? output.close(); try? errors.close(); try? source.close() }
        if let input { try source.write(contentsOf: input) }
        try source.seek(toOffset: 0)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = source
        process.standardOutput = output
        process.standardError = errors
        try commands.lock.withLock {
            try process.run()
            commands.running[process.processIdentifier] = process
        }
        defer { _ = commands.lock.withLock { commands.running.removeValue(forKey: process.processIdentifier) } }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try output.seek(toOffset: 0)
        try errors.seek(toOffset: 0)
        return HelperCommandResult(
            status: timedOut ? ETIMEDOUT : process.terminationStatus,
            standardOutput: try output.readToEnd() ?? Data(),
            standardError: (try errors.readToEnd() ?? Data()) + (timedOut ? Data("command timed out".utf8) : Data())
        )
    }
}

enum HelperCommandError: LocalizedError {
    case failed(executable: String, arguments: [String], status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case let .failed(executable, arguments, status, output):
            let summary = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(executable) \(arguments.joined(separator: " ")) failed with status \(status)"
                + (summary.isEmpty ? "" : ": \(summary)")
        }
    }
}
