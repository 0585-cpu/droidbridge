import DroidBridgeShared
import Foundation

enum NetworkInterfaces {
    static func physical(
        run: HelperCommandExecuting = HelperCommandRunner.run
    ) throws -> [String] {
        let executable = URL(fileURLWithPath: "/usr/sbin/networksetup")
        let arguments = ["-listallhardwareports"]
        let result = try run(executable, arguments, nil)
        guard result.status == 0 else {
            throw HelperCommandError.failed(
                executable: executable.path,
                arguments: arguments,
                status: result.status,
                output: result.outputText
            )
        }

        let interfaces = NetworkHardwarePortParser.interfaces(
            from: String(decoding: result.standardOutput, as: UTF8.self)
        )
        guard !interfaces.isEmpty else {
            throw HelperCommandError.failed(
                executable: executable.path,
                arguments: arguments,
                status: -1,
                output: "no physical network interfaces found"
            )
        }
        return interfaces
    }
}
