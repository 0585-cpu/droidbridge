import Darwin
import DroidBridgeShared
import Foundation

final class PfController {
    static let anchorName = "com.apple/io.droidbridge"

    private let run: HelperCommandExecuting
    private var enableToken: String?

    init(run: @escaping HelperCommandExecuting = HelperCommandRunner.run) {
        self.run = run
    }

    var isEnabled: Bool { enableToken != nil }
    var recoveryToken: String? { enableToken }

    func enable(utun: String, physical: [String]) throws {
        guard enableToken == nil else {
            throw HelperCommandError.failed(
                executable: "/sbin/pfctl",
                arguments: [],
                status: EALREADY,
                output: "the DroidBridge pf anchor is already enabled"
            )
        }
        try load(utun: utun, physical: physical)

        let enableArguments = ["-E"]
        let enableResult = try run(URL(fileURLWithPath: "/sbin/pfctl"), enableArguments, nil)
        guard enableResult.status == 0,
              let token = Self.enableToken(from: enableResult.outputText)
        else {
            _ = try? flushAnchor()
            throw commandError(enableArguments, enableResult)
        }
        enableToken = token
    }

    /// Replaces the anchor body in place; pf keeps enforcing while it swaps rulesets.
    func load(utun: String, physical: [String]) throws {
        let allInterfaces = [utun] + physical
        guard !physical.isEmpty,
              allInterfaces.allSatisfy(NetworkHardwarePortParser.isSafeInterfaceName)
        else {
            throw HelperCommandError.failed(
                executable: "/sbin/pfctl",
                arguments: [],
                status: EINVAL,
                output: "invalid or empty interface list"
            )
        }

        let body = PfRuleBuilder(utun: utun, physical: physical).anchorBody()
        let loadArguments = ["-a", Self.anchorName, "-f", "-"]
        let loadResult = try run(
            URL(fileURLWithPath: "/sbin/pfctl"),
            loadArguments,
            Data(body.utf8)
        )
        guard loadResult.status == 0 else {
            throw commandError(loadArguments, loadResult)
        }
    }

    func disable() throws {
        guard let enableToken else { return }
        let flushResult = try flushAnchor()
        guard flushResult.status == 0 else {
            throw commandError(["-a", Self.anchorName, "-F", "rules"], flushResult)
        }

        let releaseArguments = ["-X", enableToken]
        let releaseResult = try run(URL(fileURLWithPath: "/sbin/pfctl"), releaseArguments, nil)
        if releaseResult.status != 0 {
            guard try referenceIsAbsent(enableToken) else {
                throw commandError(releaseArguments, releaseResult)
            }
        }
        self.enableToken = nil
    }

    /// A crash can happen after -X succeeds but before the journal records it. A
    /// failed repeat is safe only when a successful listing proves our token absent.
    private func referenceIsAbsent(_ token: String) throws -> Bool {
        let result = try run(URL(fileURLWithPath: "/sbin/pfctl"), ["-s", "References"], nil)
        guard result.status == 0 else { return false }
        let lines = String(decoding: result.standardOutput, as: UTF8.self)
            .split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines == ["No pf starter references held"] { return true }
        guard lines.count >= 2, lines[0] == "TOKENS:",
              lines[1].split(whereSeparator: \.isWhitespace) == ["PID", "Process", "Name", "TOKEN", "TIMESTAMP"],
              let wanted = UInt64(token) else { return false }
        // Process names contain spaces; parse the numeric token beside the timestamp.
        let pattern = try NSRegularExpression(pattern: #"^[0-9]+\s+.+?\s+([0-9]+)\s+[0-9]+ days [0-9]{2}:[0-9]{2}:[0-9]{2}$"#)
        for line in lines.dropFirst(2) {
            let full = NSRange(line.startIndex..., in: line)
            guard let match = pattern.firstMatch(in: line, range: full),
                  let range = Range(match.range(at: 1), in: line),
                  let value = UInt64(line[range]) else { return false }
            if value == wanted { return false }
        }
        return true
    }

    func adoptRecoveryToken(_ token: String) throws {
        guard !token.isEmpty, token.allSatisfy(\.isNumber) else {
            throw HelperCommandError.failed(
                executable: "/sbin/pfctl",
                arguments: [],
                status: EINVAL,
                output: "invalid persisted pf enable token"
            )
        }
        enableToken = token
    }

    func clearAnchorRules() throws {
        let result = try flushAnchor()
        guard result.status == 0 else {
            throw commandError(["-a", Self.anchorName, "-F", "rules"], result)
        }
    }

    private func flushAnchor() throws -> HelperCommandResult {
        try run(
            URL(fileURLWithPath: "/sbin/pfctl"),
            ["-a", Self.anchorName, "-F", "rules"],
            nil
        )
    }

    private func commandError(_ arguments: [String], _ result: HelperCommandResult) -> HelperCommandError {
        .failed(
            executable: "/sbin/pfctl",
            arguments: arguments,
            status: result.status,
            output: result.outputText
        )
    }

    private static func enableToken(from output: String) -> String? {
        for line in output.split(whereSeparator: \Character.isNewline) {
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces) == "Token"
            else { continue }
            let token = fields[1].trimmingCharacters(in: .whitespaces)
            if !token.isEmpty, token.allSatisfy(\.isNumber) { return token }
        }
        return nil
    }
}
