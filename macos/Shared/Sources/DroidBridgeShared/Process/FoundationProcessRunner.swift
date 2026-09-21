import Foundation

/// Real process runner. Captures at most 1 MiB of stdout/stderr and terminates the child on cancellation.
public struct FoundationProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: URL, arguments: [String], environment: [String: String]) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    let out = FoundationProcessRunner.read(outPipe)
                    let err = FoundationProcessRunner.read(errPipe)
                    continuation.resume(returning: ProcessResult(exitCode: proc.terminationStatus, stdout: out, stderr: err))
                }
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: DroidBridgeError.adbCommandFailed(exitCode: -1, message: error.localizedDescription))
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static let maxCapture = 1 << 20
    private static func read(_ pipe: Pipe) -> Data {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return data.count > maxCapture ? data.prefix(maxCapture) : data
    }
}
