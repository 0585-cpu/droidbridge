import Foundation

/// Parses `/usr/sbin/networksetup -listallhardwareports` without trusting its text as pf syntax.
public enum NetworkHardwarePortParser {
    public static func interfaces(from output: String) -> [String] {
        var seen = Set<String>()
        return output.split(whereSeparator: \Character.isNewline).compactMap { line in
            let fields = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2,
                  fields[0].trimmingCharacters(in: .whitespaces) == "Device"
            else { return nil }
            let name = fields[1].trimmingCharacters(in: .whitespaces)
            guard isSafeInterfaceName(name), seen.insert(name).inserted else { return nil }
            return name
        }
    }

    public static func isSafeInterfaceName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 15 else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 45, 46, 48...57, 65...90, 95, 97...122:
                return true
            default:
                return false
            }
        }
    }
}
