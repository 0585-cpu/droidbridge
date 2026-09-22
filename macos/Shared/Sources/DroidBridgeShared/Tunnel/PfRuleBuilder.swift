import Foundation

/// Builds the fail-closed `com.apple/io.droidbridge` pf anchor body.
public struct PfRuleBuilder: Sendable {
    public let utun: String
    public let physical: [String]

    public init(utun: String, physical: [String]) {
        self.utun = utun
        self.physical = physical
    }

    public func anchorBody() -> String {
        var lines = [
            "set block-policy drop",
            "pass quick on lo0",
            "pass quick on \(utun)",
        ]
        lines.append(contentsOf: physical.map { "block drop out quick on \($0) all" })
        return lines.joined(separator: "\n") + "\n"
    }
}
