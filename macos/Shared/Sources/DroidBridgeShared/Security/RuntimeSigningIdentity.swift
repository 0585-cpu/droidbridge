import Foundation

/// Reads the build-time team identifier from the current binary's signed Info
/// dictionary. The value is part of the code-signature seal and lets arbitrary
/// development teams build mutually authenticated app/helper pairs.
public enum RuntimeSigningIdentity {
    public static let infoKey = "DroidBridgeTeamIdentifier"
    public static let keychainAccessGroupSuffix = "io.droidbridge.shared"

    public static func teamID(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: infoKey) as? String else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: allowed.inverted) == nil
        else { return nil }
        return trimmed
    }

    public static func keychainAccessGroup(teamID: String) -> String? {
        let trimmed = teamID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
        else { return nil }
        return "\(trimmed).\(keychainAccessGroupSuffix)"
    }

    public static func keychainAccessGroup(bundle: Bundle = .main) -> String? {
        guard let teamID = teamID(bundle: bundle) else { return nil }
        return keychainAccessGroup(teamID: teamID)
    }
}
