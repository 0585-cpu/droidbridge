import DroidBridgeShared

func runNetworkServiceChecks(_ r: CheckRunner) {
    let id = TunnelNetworkService.serviceID
    guard let script = TunnelNetworkService.publishScript(utun: "utun9") else {
        r.check(false, "a kernel utun name must be publishable")
        r.finish("network service")
        return
    }
    let lines = script.split(separator: "\n").map(String.init)
    r.check(lines.contains("d.add InterfaceName utun9"), "service is bound to the tunnel interface")
    r.check(lines.contains("d.add Addresses * 198.18.0.2"), "service carries the tunnel address")
    r.check(lines.contains("d.add DestAddresses * 198.18.0.1"), "service carries the point-to-point peer")
    r.check(lines.contains("d.add Router 198.18.0.1"), "service routes through the virtual gateway")
    // Without OverridePrimary configd keeps the physical service primary and
    // rewrites the default route back to it on every network change.
    r.check(lines.contains("d.add OverridePrimary # 1"), "service overrides the primary network")
    r.check(lines.contains("set State:/Network/Service/\(id)/IPv4"), "IPv4 state is published under our id")
    r.check(lines.contains("d.add ServerAddresses * 198.18.0.1"), "service resolver is the tunnel's virtual DNS")
    r.check(lines.contains("set State:/Network/Service/\(id)/DNS"), "DNS state is published under our id")
    r.check(lines.last == "quit", "script terminates scutil")

    // The interface name is interpolated into a scutil script; a newline would
    // let it inject arbitrary configd commands.
    r.check(TunnelNetworkService.publishScript(utun: "utun9\nremove State:/Network/Global/IPv4") == nil,
            "an interface name cannot inject scutil commands")
    r.check(TunnelNetworkService.publishScript(utun: "en0") == nil, "only a utun can be published as the tunnel")

    let remove = TunnelNetworkService.removeScript.split(separator: "\n").map(String.init)
    r.check(remove.contains("remove State:/Network/Service/\(id)/IPv4"), "withdraw removes IPv4 state")
    r.check(remove.contains("remove State:/Network/Service/\(id)/DNS"), "withdraw removes DNS state")

    let global = """
    <dictionary> {
      PrimaryInterface : utun6
      PrimaryService : \(id)
      Router : 198.18.0.1
    }
    """
    r.check(TunnelNetworkService.primaryInterface(from: global) == "utun6", "primary interface is read back")
    r.check(TunnelNetworkService.primaryInterface(from: "  No such key\n") == nil, "no primary means nil")
    r.check(lines.contains("d.add PrefixLength * # 64"), "IPv6 prefix lengths are CFNumber array")
    r.check(lines.contains("set State:/Network/Service/\(id)/IPv6"), "IPv6 primary state is always captured")
    r.check(remove.contains("remove State:/Network/Service/\(id)/IPv6"), "withdraw removes IPv6 state")
    r.finish("network service")
}
