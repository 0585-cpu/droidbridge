import Foundation

public struct PairingHello: Equatable, Sendable {
    public let role: String
    public let peerId: String
    public let displayName: String
    public let publicKey: Data   // X9.63 uncompressed, 65 bytes
    public let nonce: Data       // 32 bytes

    public init(role: String, peerId: String, displayName: String, publicKey: Data, nonce: Data) {
        self.role = role; self.peerId = peerId; self.displayName = displayName
        self.publicKey = publicKey; self.nonce = nonce
    }

    public var canonicalJSON: String {
        PairingCanonicalJSON.hello(role: role, peerId: peerId, displayName: displayName, publicKey: publicKey, nonce: nonce)
    }

    public static func parse(_ json: String) throws -> PairingHello {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw DroidBridgeError.pairingProtocol("hello json")
        }
        guard (object["version"] as? Int) == 1 else { throw DroidBridgeError.pairingProtocol("version") }
        guard let role = object["role"] as? String, role == "mac" || role == "android" else { throw DroidBridgeError.pairingProtocol("role") }
        guard let peerId = object["peerId"] as? String,
              let publicKeyB64 = object["publicKey"] as? String, let publicKey = Data(base64Encoded: publicKeyB64),
              let nonceB64 = object["nonce"] as? String, let nonce = Data(base64Encoded: nonceB64) else {
            throw DroidBridgeError.pairingProtocol("hello fields")
        }
        let displayName = object["displayName"] as? String ?? ""
        guard publicKey.count == 65, nonce.count == 32 else { throw DroidBridgeError.pairingProtocol("hello sizes") }
        return PairingHello(role: role, peerId: peerId, displayName: displayName, publicKey: publicKey, nonce: nonce)
    }
}

public struct PairingApproval: Equatable, Sendable {
    public let sessionId: String
    public let approved: Bool
    public let proof: Data?
    public init(sessionId: String, approved: Bool, proof: Data?) {
        self.sessionId = sessionId; self.approved = approved; self.proof = proof
    }
    public var canonicalJSON: String { PairingCanonicalJSON.approval(sessionId: sessionId, approved: approved, proof: proof) }

    public static func parse(_ json: String) throws -> PairingApproval {
        guard let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let sessionId = object["sessionId"] as? String, let approved = object["approved"] as? Bool else {
            throw DroidBridgeError.pairingProtocol("approval json")
        }
        let proof = (object["proof"] as? String).flatMap { Data(base64Encoded: $0) }
        return PairingApproval(sessionId: sessionId, approved: approved, proof: proof)
    }
}

public struct PairingResult: Sendable {
    public let peerId: String
    public let displayName: String
    public let secret: Data
    public init(peerId: String, displayName: String, secret: Data) {
        self.peerId = peerId; self.displayName = displayName; self.secret = secret
    }
}
