import DroidBridgeShared

func runPfRouteChecks(_ r: CheckRunner) {
    let rules = PfRuleBuilder(utun: "utun4", physical: ["en0", "en1"]).anchorBody()
    r.check(rules.contains("pass quick on lo0"), "loopback relay is allowed")
    r.check(rules.contains("pass quick on utun4"), "tunnel traffic is allowed")
    r.check(rules.contains("block return out quick on en0 all"), "en0 egress is blocked")
    r.check(rules.contains("block return out quick on en1 all"), "en1 egress is blocked")
    r.check(!rules.contains("pass quick on en"), "physical interfaces have no pass rule")

    // Enumerating interfaces to block is default-allow: anything `networksetup`
    // does not list (awdl0, llw0, a foreign VPN's utun0, an interface hotplugged
    // after start) matches no rule and pf then passes it. The ruleset must deny
    // by default so only lo0 and our own utun can ever egress.
    r.check(rules.contains("block return out all"), "ruleset denies egress by default")
    let catchAll = rules.range(of: "block return out all")
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
    // A silent drop black-holes connections that were opened on the physical
    // interface before the tunnel started (seen live: the Claude app's own
    // api.anthropic.com socket stayed bound to en0), so apps hang until a TCP
    // timeout. Returning RST/ICMP makes them fail at once and reconnect through
    // utun; nothing is transmitted on the physical interface either way.
    r.check(!rules.contains("block drop"), "no rule silently drops traffic")
    r.check(rules.contains("set block-policy return"), "default block policy returns an error")
    r.finish("pf and route")
}
