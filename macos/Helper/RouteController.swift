import Darwin
import DroidBridgeShared
import Foundation

final class RouteController {
    private let run: HelperCommandExecuting
    private var savedGateway: String?
    private var activeUtun: String?
    private var utunRouteInstalled = false

    init(run: @escaping HelperCommandExecuting = HelperCommandRunner.run) {
        self.run = run
    }

    var isConfigured: Bool { savedGateway != nil }

    func setDefault(utun: String) throws {
        _ = try prepareDefault(utun: utun)
        try installDefault()
    }

    @discardableResult
    func prepareDefault(utun: String) throws -> String {
        guard savedGateway == nil else {
            throw HelperCommandError.failed(
                executable: "/sbin/route",
                arguments: [],
                status: EALREADY,
                output: "the tunnel default route is already configured"
            )
        }
        guard NetworkHardwarePortParser.isSafeInterfaceName(utun) else {
            throw HelperCommandError.failed(
                executable: "/sbin/route",
                arguments: [],
                status: EINVAL,
                output: "invalid utun interface name"
            )
        }

        let gateway = try currentDefaultGateway()
        savedGateway = gateway
        activeUtun = utun
        return gateway
    }

    func installDefault() throws {
        guard let gateway = savedGateway, let utun = activeUtun else {
            throw HelperCommandError.failed(
                executable: "/sbin/route",
                arguments: [],
                status: EINVAL,
                output: "the tunnel default route was not prepared"
            )
        }
        let commands = RouteCommandBuilder(utun: utun).setDefault(gateway: gateway)

        let deleteResult = try execute(commands[0])
        guard deleteResult.status == 0 else {
            savedGateway = nil
            activeUtun = nil
            utunRouteInstalled = false
            throw commandError(commands[0], deleteResult)
        }

        let addResult = try execute(commands[1])
        guard addResult.status == 0 else {
            let originalError = commandError(commands[1], addResult)
            do {
                try restore()
            } catch {
                throw HelperCommandError.failed(
                    executable: "/sbin/route",
                    arguments: commands[1],
                    status: addResult.status,
                    output: "\(originalError.localizedDescription); rollback failed: \(error.localizedDescription)"
                )
            }
            throw originalError
        }
        utunRouteInstalled = true
    }

    func adoptRecoveryState(gateway: String, utun: String) throws {
        guard isIPv4Address(gateway), NetworkHardwarePortParser.isSafeInterfaceName(utun) else {
            throw HelperCommandError.failed(
                executable: "/sbin/route",
                arguments: [],
                status: EINVAL,
                output: "invalid persisted route recovery state"
            )
        }
        savedGateway = gateway
        activeUtun = utun
        // State is written before the route mutation. restore() verifies whether
        // the utun route actually exists before treating a failed delete as fatal.
        utunRouteInstalled = true
    }

    func restore() throws {
        guard let gateway = savedGateway, let utun = activeUtun else { return }
        let commands = RouteCommandBuilder(utun: utun).restoreDefault(gateway: gateway)

        if utunRouteInstalled {
            let deleteResult = try execute(commands[0])
            if deleteResult.status == 0 {
                // Clear this immediately. If restoring the gateway fails, the
                // next retry must not try to delete an already-removed route.
                utunRouteInstalled = false
            } else if try defaultRouteUsesInterface(utun) {
                throw commandError(commands[0], deleteResult)
            } else {
                // The helper may have restarted after the route was already
                // removed. Recovery remains safe and idempotent.
                utunRouteInstalled = false
            }
        }
        let restoreResult = try execute(commands[1])
        let restoredGateway = try? currentDefaultGateway()
        guard restoreResult.status == 0 || restoredGateway == gateway else {
            throw commandError(commands[1], restoreResult)
        }

        savedGateway = nil
        activeUtun = nil
        utunRouteInstalled = false
    }

    private func currentDefaultGateway() throws -> String {
        let executable = URL(fileURLWithPath: "/sbin/route")
        let arguments = ["-n", "get", "default"]
        let result = try run(executable, arguments, nil)
        guard result.status == 0,
              let gatewayLine = String(decoding: result.standardOutput, as: UTF8.self)
                .split(whereSeparator: \Character.isNewline)
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gateway:") }),
              let gateway = gatewayLine.split(separator: ":", maxSplits: 1).last?
                .trimmingCharacters(in: .whitespaces),
              isIPv4Address(gateway)
        else {
            throw HelperCommandError.failed(
                executable: executable.path,
                arguments: arguments,
                status: result.status,
                output: result.outputText.isEmpty ? "no IPv4 default gateway" : result.outputText
            )
        }
        return gateway
    }

    private func defaultRouteUsesInterface(_ interface: String) throws -> Bool {
        let executable = URL(fileURLWithPath: "/sbin/route")
        let arguments = ["-n", "get", "default"]
        let result = try run(executable, arguments, nil)
        guard result.status == 0 else { return false }
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        return output
            .split(whereSeparator: \Character.isNewline)
            .contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed == "interface: \(interface)"
            }
    }

    private func execute(_ command: [String]) throws -> HelperCommandResult {
        guard command.first == "route" else {
            throw HelperCommandError.failed(
                executable: "/sbin/route",
                arguments: command,
                status: EINVAL,
                output: "unexpected command"
            )
        }
        return try run(URL(fileURLWithPath: "/sbin/route"), Array(command.dropFirst()), nil)
    }

    private func commandError(_ command: [String], _ result: HelperCommandResult) -> HelperCommandError {
        .failed(
            executable: "/sbin/route",
            arguments: Array(command.dropFirst()),
            status: result.status,
            output: result.outputText
        )
    }

    private func isIPv4Address(_ value: String) -> Bool {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) } == 1
    }
}
