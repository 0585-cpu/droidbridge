import DroidBridgeShared

func runPfRouteChecks(_ r: CheckRunner) {
    let rules = PfRuleBuilder(utun: "utun4", physical: ["en0", "en1"]).anchorBody()
    r.check(rules.contains("pass quick on lo0"), "loopback relay is allowed")
    r.check(rules.contains("pass quick on utun4"), "tunnel traffic is allowed")
    r.check(rules.contains("block drop out quick on en0 all"), "en0 egress is blocked")
    r.check(rules.contains("block drop out quick on en1 all"), "en1 egress is blocked")
    r.check(!rules.contains("pass quick on en"), "physical interfaces have no pass rule")

    // Enumerating interfaces to block is default-allow: anything `networksetup`
    // does not list (awdl0, llw0, a foreign VPN's utun0, an interface hotplugged
    // after start) matches no rule and pf then passes it. The ruleset must deny
    // by default so only lo0 and our own utun can ever egress.
    r.check(rules.contains("block drop out all"), "ruleset denies egress by default")
    let catchAll = rules.range(of: "block drop out all")
    let loopbackPass = rules.range(of: "pass quick on lo0")
    r.check(
        catchAll != nil && loopbackPass != nil && catchAll!.lowerBound < loopbackPass!.lowerBound,
        "default deny precedes the quick pass exceptions"
    )
    for unlisted in ["awdl0", "llw0", "utun0", "en9"] {
        r.check(!rules.contains("pass quick on \(unlisted)"), "\(unlisted) has no pass rule")
    }
    // A foreign tunnel must not inherit our own utun's exemption.
    let otherTunnel = PfRuleBuilder(utun: "utun4", physical: ["en0"]).anchorBody()
    r.check(!otherTunnel.contains("pass quick on utun0"), "foreign utun is not exempted")

    let commands = RouteCommandBuilder(utun: "utun4")
    r.check(
        commands.setDefault(gateway: "192.168.0.1") == [
            ["route", "-n", "delete", "-inet", "default", "192.168.0.1"],
            ["route", "-n", "add", "-inet", "default", "-interface", "utun4"],
        ],
        "original default is removed before the utun default is added"
    )
    r.check(
        commands.setDefault().contains(["route", "-n", "add", "-inet", "default", "-interface", "utun4"]),
        "default route targets utun"
    )
    r.check(
        commands.restoreDefault(gateway: "192.168.0.1").contains(["route", "-n", "add", "-inet", "default", "192.168.0.1"]),
        "original gateway is restored"
    )

    let hardwarePorts = """
    Hardware Port: Wi-Fi
    Device: en0
    Ethernet Address: 00:11:22:33:44:55

    Hardware Port: Thunderbolt Ethernet
    Device: en5
    Ethernet Address: 00:11:22:33:44:66
    """
    r.check(
        NetworkHardwarePortParser.interfaces(from: hardwarePorts) == ["en0", "en5"],
        "physical interface parser extracts networksetup devices"
    )
    r.check(NetworkHardwarePortParser.isSafeInterfaceName("en0"), "accepts a kernel interface name")
    r.check(!NetworkHardwarePortParser.isSafeInterfaceName("en0\nblock all"), "rejects pf rule injection")
    r.finish("pf and route")
}
