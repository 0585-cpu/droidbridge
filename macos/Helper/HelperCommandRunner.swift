import Foundation

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
    static func run(
        executable: URL,
        arguments: [String],
        input: Data? = nil
    ) throws -> HelperCommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let inputPipe: Pipe?
        if input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            inputPipe = nil
        }

        try process.run()
        if let input, let inputPipe {
            inputPipe.fileHandleForWriting.write(input)
            try inputPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        return HelperCommandResult(
            status: process.terminationStatus,
            standardOutput: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            standardError: errorPipe.fileHandleForReading.readDataToEndOfFile()
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
