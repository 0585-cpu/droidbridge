import DroidBridgeShared
import Foundation

enum NetworkInterfaces {
    /// Every `en*` kernel interface (Ethernet, Wi-Fi, USB LAN, iPhone USB) without asking configd.
    static func kernelEthernet() -> [String] {
        guard let list = if_nameindex() else { return [] }
        defer { if_freenameindex(list) }
        var names: [String] = []
        var entry = list
        while entry.pointee.if_index != 0 {
            let name = String(cString: entry.pointee.if_name)
            if name.hasPrefix("en") { names.append(name) }
            entry += 1
        }
        return names
    }

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
