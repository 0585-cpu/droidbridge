import Foundation

/// Produces deterministic `route` argument vectors for tunnel setup and rollback.
public struct RouteCommandBuilder: Sendable {
    public let utun: String

    public init(utun: String) {
        self.utun = utun
    }

    public func setDefault(gateway: String? = nil) -> [[String]] {
        var commands: [[String]] = []
        if let gateway {
            commands.append(["route", "-n", "delete", "-inet", "default", gateway])
        }
        commands.append(["route", "-n", "add", "-inet", "default", "-interface", utun])
        return commands
    }

    public func restoreDefault(gateway: String) -> [[String]] {
        [
            ["route", "-n", "delete", "-inet", "default", "-interface", utun],
            ["route", "-n", "add", "-inet", "default", gateway],
        ]
    }
}
