import Foundation

/// Byte-exact canonical JSON matching Android `io.droidbridge.util.Json` and the Python probe:
/// sorted keys, no insignificant whitespace, integer `version`, base64 (standard, padded) for bytes.
/// Assumes ASCII display names (device model / user labels), as the peers do.
public enum PairingCanonicalJSON {
    public static func hello(role: String, peerId: String, displayName: String, publicKey: Data, nonce: Data) -> String {
        // keys already in sorted order: displayName, nonce, peerId, publicKey, role, version
        var out = "{"
        out += "\"displayName\":\(escaped(displayName)),"
        out += "\"nonce\":\(escaped(nonce.base64EncodedString())),"
        out += "\"peerId\":\(escaped(peerId)),"
        out += "\"publicKey\":\(escaped(publicKey.base64EncodedString())),"
        out += "\"role\":\(escaped(role)),"
        out += "\"version\":1"
        out += "}"
        return out
    }

    public static func approval(sessionId: String, approved: Bool, proof: Data?) -> String {
        // sorted keys: approved, proof, sessionId
        let proofValue = proof.map { escaped($0.base64EncodedString()) } ?? "null"
        return "{\"approved\":\(approved),\"proof\":\(proofValue),\"sessionId\":\(escaped(sessionId))}"
    }

    private static func escaped(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case let c where c.value < 0x20: out += String(format: "\\u%04x", c.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
        return out
    }
}
