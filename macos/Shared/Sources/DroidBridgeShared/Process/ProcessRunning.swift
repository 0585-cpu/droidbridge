import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: Data
    public let stderr: Data
    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs an executable with an explicit argument vector — never a shell — and is cancellation-aware:
/// cancelling the calling task must terminate the child process.
public protocol ProcessRunning: Sendable {
    func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult
}
