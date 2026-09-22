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

    func enable(utun: String, physical: [String]) throws {
        guard enableToken == nil else {
            throw HelperCommandError.failed(
                executable: "/sbin/pfctl",
                arguments: [],
                status: EALREADY,
                output: "the DroidBridge pf anchor is already enabled"
            )
        }
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

    func disable() throws {
        guard let enableToken else { return }
        let flushResult = try flushAnchor()
        guard flushResult.status == 0 else {
            throw commandError(["-a", Self.anchorName, "-F", "rules"], flushResult)
        }

        let releaseArguments = ["-X", enableToken]
        let releaseResult = try run(URL(fileURLWithPath: "/sbin/pfctl"), releaseArguments, nil)
        guard releaseResult.status == 0 else {
            throw commandError(releaseArguments, releaseResult)
        }
        self.enableToken = nil
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
