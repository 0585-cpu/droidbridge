import Foundation

/// Exposes the bundled canonical DBP/1 test vectors to the checks/tests target.
public enum DbpFixtures {
    public static func extensionsJSON() -> Data? {
        guard let url = Bundle.module.url(forResource: "dbp-extensions", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
    public static func v1JSON() -> Data? {
        guard let url = Bundle.module.url(forResource: "dbp-v1", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}
