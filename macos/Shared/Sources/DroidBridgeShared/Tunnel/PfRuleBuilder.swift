import Foundation

/// Builds the fail-closed `com.apple/io.droidbridge` pf anchor body.
public struct PfRuleBuilder: Sendable {
    public let utun: String
    public let physical: [String]

    public init(utun: String, physical: [String]) {
        self.utun = utun
        self.physical = physical
    }

    /// Denies egress by default. Enumerating interfaces to block would be
    /// default-allow: anything `networksetup` does not list (awdl0, llw0, a
    /// foreign VPN's utun, an interface hotplugged after start) would match no
    /// rule and pf would pass it. The catch-all is non-quick so the `pass quick`
    /// exceptions for loopback (the relay) and our own utun still short-circuit;
    /// everything else falls through to the deny. The explicit per-interface
    /// blocks are kept for operator legibility in `pfctl -a … -s rules`.
    public func anchorBody() -> String {
        var lines = [
            "set block-policy drop",
            "block drop out all",
            "pass quick on lo0",
            "pass quick on \(utun)",
        ]
        lines.append(contentsOf: physical.map { "block drop out quick on \($0) all" })
        return lines.joined(separator: "\n") + "\n"
    }
}
