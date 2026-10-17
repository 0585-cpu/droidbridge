import NetworkExtension
import DroidBridgeShared

/// The only mapping from the shared descriptor to NEPacketTunnelNetworkSettings.
enum TunnelSettings {
    static func make(from descriptor: TunnelSettingsDescriptor = .b1) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: descriptor.gateway)

        let ipv4 = NEIPv4Settings(addresses: [descriptor.address], subnetMasks: [descriptor.subnetMask])
        ipv4.includedRoutes = descriptor.includedRoutes.map { route in
            route == "0.0.0.0/0" ? NEIPv4Route.default() : NEIPv4Route(destinationAddress: route, subnetMask: "255.255.255.255")
        }
        ipv4.excludedRoutes = descriptor.excludedRoutes.map { route -> NEIPv4Route in
            let parts = route.split(separator: "/")
            // 127.0.0.0/8
            return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: "255.0.0.0")
        }
        settings.ipv4Settings = ipv4
        let ipv6 = NEIPv6Settings(addresses: [TunnelNetworkService.ipv6Address], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = [NEIPv6Route(destinationAddress: "::1", networkPrefixLength: 128)]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: descriptor.dnsServers)
        dns.matchDomains = [""] // route all DNS through the tunnel resolver
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: descriptor.mtu)
        return settings
    }
}
