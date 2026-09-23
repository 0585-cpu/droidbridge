import Darwin
import Foundation

/// Parses `networksetup -listnetworkserviceorder`.
public enum NetworkServiceOrderParser {
    /// Enabled services bound to an interface: exactly the ones that can become
    /// the primary service and therefore supply the system resolver. A disabled
    /// service is listed as `(*) Name`; a device-less one (e.g. a VPN profile)
    /// has an empty `Device:`.
    public static func servicesWithDevices(from output: String) -> [String] {
        var services: [String] = []
        var pending: String?
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("(Hardware Port:") {
                defer { pending = nil }
                guard let name = pending,
                      let marker = line.range(of: ", Device: ", options: .backwards)
                else { continue }
                let device = line[marker.upperBound...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: ") "))
                if !device.isEmpty { services.append(name) }
            } else if line.hasPrefix("("), let close = line.firstIndex(of: ")") {
                let index = line[line.index(after: line.startIndex)..<close]
                let name = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                pending = (index.allSatisfy(\.isNumber) && !index.isEmpty && !name.isEmpty) ? name : nil
            }
        }
        return services
    }
}

/// Parses `networksetup -getdnsservers <service>`.
public enum DnsServerListParser {
    /// `[]` when the service has no manual servers (DHCP-provided DNS), the
    /// manual list otherwise, and `nil` for anything unrecognized. The nil case
    /// matters: treating an error as "DHCP" would restore `Empty` and silently
    /// erase a user's manual DNS.
    public static func servers(from output: String) -> [String]? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        if lines.count == 1, lines[0].hasPrefix("There aren't any DNS Servers set on ") {
            return []
        }
        return lines.allSatisfy(isValidServer) ? lines : nil
    }

    /// An IPv4 or IPv6 literal, optionally with a `%scope` for link-local.
    public static func isValidServer(_ value: String) -> Bool {
        let address = value.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ""
        var v4 = in_addr()
        var v6 = in6_addr()
        return address.withCString { inet_pton(AF_INET, $0, &v4) } == 1
            || address.withCString { inet_pton(AF_INET6, $0, &v6) } == 1
    }
}

/// Generates `networksetup` arguments that point services at the tunnel's
/// virtual resolver and put them back exactly as they were.
public enum DnsCommandBuilder {
    public static let tunnelResolver = "198.18.0.1"

    public static func pointAtTunnel(service: String) -> [String] {
        ["-setdnsservers", service, tunnelResolver]
    }

    public static func restore(service: String, servers: [String]) -> [String] {
        ["-setdnsservers", service] + (servers.isEmpty ? ["Empty"] : servers)
    }
}
