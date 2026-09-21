import Foundation
import CryptoKit

/// P-256 ECDH + HKDF-SHA256 + SAS, matching Android PairingProtocol and tools/pairing_probe.py.
public enum PairingCrypto {
    static let transcriptPrefix = Data("DROIDBRIDGE-PAIR-1".utf8)
    static let hkdfInfo = Data("DroidBridge DBP/1 Pairing".utf8)

    public static func transcript(macHelloJSON: String, androidHelloJSON: String) -> Data {
        transcriptPrefix + Data(macHelloJSON.utf8) + Data(androidHelloJSON.utf8)
    }

    public static func deriveSecret(privateKey: P256.KeyAgreement.PrivateKey,
                                    peerPublicKey: P256.KeyAgreement.PublicKey,
                                    macNonce: Data, androidNonce: Data) throws -> Data {
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: macNonce + androidNonce,
                                                 sharedInfo: hkdfInfo, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    public static func sas(transcript: Data) -> String {
        let digest = SHA256.hash(data: transcript)
        let bytes = Array(digest.prefix(4))
        let value = (UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3])
        return String(format: "%06d", value % 1_000_000)
    }

    public static func sessionId(transcript: Data) -> String {
        SHA256.hash(data: transcript).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public static func approvalProof(secret: Data, role: String, transcript: Data) -> Data {
        let message = Data(role.utf8) + Data([0]) + Data(SHA256.hash(data: transcript))
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: secret))
        return Data(mac)
    }

    public static func verifyApprovalProof(secret: Data, role: String, transcript: Data, proof: Data) -> Bool {
        let expected = approvalProof(secret: secret, role: role, transcript: transcript)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: Data(role.utf8) + Data([0]) + Data(SHA256.hash(data: transcript)), using: SymmetricKey(data: secret))
            || expected == proof
    }
}
