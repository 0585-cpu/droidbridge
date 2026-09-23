import DroidBridgeShared

func runDnsServiceChecks(_ r: CheckRunner) {
    // Real `networksetup -listnetworkserviceorder` shape, plus a disabled service.
    let order = """
    An asterisk (*) denotes that a network service is disabled.
    (1) USB 10/100/1000 LAN
    (Hardware Port: USB 10/100/1000 LAN, Device: en7)

    (2) Thunderbolt Bridge
    (Hardware Port: Thunderbolt Bridge, Device: bridge0)

    (3) Wi-Fi
    (Hardware Port: Wi-Fi, Device: en0)

    (4) Tailscale
    (Hardware Port: io.tailscale.ipn.macos, Device: )

    (*) Bluetooth PAN
    (Hardware Port: Bluetooth PAN, Device: en9)
    """
    let services = NetworkServiceOrderParser.servicesWithDevices(from: order)
    r.check(services == ["USB 10/100/1000 LAN", "Thunderbolt Bridge", "Wi-Fi"],
            "only enabled services bound to an interface can supply the resolver")
    r.check(!services.contains("Tailscale"), "a service without a device is skipped")
    r.check(!services.contains("Bluetooth PAN"), "a disabled service is skipped")

    // `-getdnsservers` distinguishes DHCP-provided DNS from a manual list and from an error.
    r.check(DnsServerListParser.servers(from: "There aren't any DNS Servers set on Wi-Fi.\n") == [],
            "no manual servers means DHCP-provided")
    r.check(DnsServerListParser.servers(from: "8.8.8.8\n") == ["8.8.8.8"], "a manual server is read")
    r.check(DnsServerListParser.servers(from: "8.8.8.8\n2001:4860:4860::8888\n")
            == ["8.8.8.8", "2001:4860:4860::8888"], "mixed IPv4/IPv6 manual servers are read")
    r.check(DnsServerListParser.servers(from: "fe80::1%en0\n") == ["fe80::1%en0"],
            "a scoped link-local server keeps its scope")
    r.check(DnsServerListParser.servers(from: "** Error: The parameters were not valid.\n") == nil,
            "an error is not mistaken for DHCP (that would erase manual DNS on restore)")
    r.check(DnsServerListParser.servers(from: "") == nil, "empty output is unrecognized")

    r.check(DnsCommandBuilder.tunnelResolver == "198.18.0.1", "tunnel resolver is the virtual DNS")
    r.check(DnsCommandBuilder.pointAtTunnel(service: "Wi-Fi")
            == ["-setdnsservers", "Wi-Fi", "198.18.0.1"], "service is pointed at the tunnel")
    r.check(DnsCommandBuilder.restore(service: "Wi-Fi", servers: [])
            == ["-setdnsservers", "Wi-Fi", "Empty"], "DHCP-provided DNS restores as Empty")
    r.check(DnsCommandBuilder.restore(service: "USB 10/100/1000 LAN", servers: ["8.8.8.8"])
            == ["-setdnsservers", "USB 10/100/1000 LAN", "8.8.8.8"], "manual DNS is restored verbatim")

    // The invariant that matters most: whatever the user had is what comes back.
    let manual = DnsServerListParser.servers(from: "8.8.8.8\n1.0.0.1\n")!
    r.check(DnsCommandBuilder.restore(service: "USB 10/100/1000 LAN", servers: manual)
            == ["-setdnsservers", "USB 10/100/1000 LAN", "8.8.8.8", "1.0.0.1"],
            "capture -> restore round-trips a manual list exactly")

    r.check(DnsServerListParser.isValidServer("8.8.8.8"), "IPv4 server is valid")
    r.check(DnsServerListParser.isValidServer("fe80::1%en0"), "scoped IPv6 server is valid")
    r.check(!DnsServerListParser.isValidServer("8.8.8.8; rm -rf /"), "garbage is rejected")
    r.check(!DnsServerListParser.isValidServer("Empty"), "the Empty keyword is not a server")
    r.finish("dns service")
}
