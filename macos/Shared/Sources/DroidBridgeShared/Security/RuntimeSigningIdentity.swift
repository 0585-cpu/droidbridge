import Foundation

/// Reads the build-time team identifier from the current binary's signed Info
/// dictionary. The value is part of the code-signature seal and lets arbitrary
/// development teams build mutually authenticated app/helper pairs.
public enum RuntimeSigningIdentity {
    public static let infoKey = "DroidBridgeTeamIdentifier"

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
}
