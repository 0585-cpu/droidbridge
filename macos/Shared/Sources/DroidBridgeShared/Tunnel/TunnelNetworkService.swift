import Foundation

/// Publishes the tunnel to configd as a network service that overrides the
/// primary one.
///
/// configd owns the default route and the system resolver and rewrites both
/// whenever the network changes (Wi-Fi or hotspot on/off, DHCP renewal, wake).
/// A default route installed behind its back with `route add` is silently
/// replaced by the physical one on the next change, which the pf kill-switch
/// then blocks. As a primary service, configd itself keeps the default route
/// on utun, uses the tunnel's virtual resolver, and reports the Mac as online
/// even when no physical network is left. Removing the keys hands everything
/// back to configd, which restores the physical network on its own.
public enum TunnelNetworkService {
    public static let serviceID = "D801B21D-0000-4000-8000-00000000D801"
    public static let localAddress = "198.18.0.2"
    /// The utun peer: the virtual gateway and the virtual DNS resolver.
    public static let gateway = "198.18.0.1"

    public static let ipv6Address = "fd42:6472:6f69::2"
    public static let ipv6Gateway = "fd42:6472:6f69::1"

    /// scutil commands that publish the service, or nil when `utun` is not a
    /// plain utun name (it is interpolated into the script).
    public static func publishScript(utun: String) -> String? {
        guard utun.hasPrefix("utun"),
              NetworkHardwarePortParser.isSafeInterfaceName(utun)
        else { return nil }
        return [
            "d.init",
            "d.add Addresses * \(localAddress)",
            "d.add DestAddresses * \(gateway)",
            "d.add InterfaceName \(utun)",
            "d.add Router \(gateway)",
            "d.add OverridePrimary # 1",
            "set State:/Network/Service/\(serviceID)/IPv4",
            "d.init",
            "d.add Addresses * \(ipv6Address)",
            "d.add PrefixLength * # 64",
            "d.add InterfaceName \(utun)",
            "d.add Router \(ipv6Gateway)",
            "d.add OverridePrimary # 1",
            "set State:/Network/Service/\(serviceID)/IPv6",
            "d.init",
            "d.add ServerAddresses * \(gateway)",
            "set State:/Network/Service/\(serviceID)/DNS",
            "quit",
        ].joined(separator: "\n") + "\n"
    }

    /// Idempotent: removing keys that are not there is harmless, so this is
    /// also the crash-recovery path.
    public static let removeScript = [
        "remove State:/Network/Service/\(serviceID)/IPv4",
        "remove State:/Network/Service/\(serviceID)/IPv6",
        "remove State:/Network/Service/\(serviceID)/DNS",
        "quit",
    ].joined(separator: "\n") + "\n"

    public static let primaryQuery = "show State:/Network/Global/IPv4\nquit\n"

    public static let primaryIPv6Query = "show State:/Network/Global/IPv6\nquit\n"

    /// Reads `PrimaryInterface` from `show State:/Network/Global/IPv4`.
    public static func primaryInterface(from output: String) -> String? {
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespaces) == "PrimaryInterface"
            else { continue }
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }
}
