import Foundation
import CryptoKit

/// One pairing conversation with the Android endpoint. Frame = 4-byte big-endian length + JSON, cap 8192.
public protocol PairingConnection: Sendable {
    func sendFrame(_ data: Data) async throws
    func receiveFrame() async throws -> Data
    func close() async
}

public enum PairingFraming {
    public static let maxFrame = 8192
    public static func encode(_ json: String) throws -> Data {
        let body = Data(json.utf8)
        guard body.count <= maxFrame else { throw DroidBridgeError.pairingFrameTooLarge }
        var out = Data(count: 4)
        let n = UInt32(body.count).bigEndian
        withUnsafeBytes(of: n) { out.replaceSubrange(0..<4, with: $0) }
        return out + body
    }
}

/// Drives the Mac side of pairing. Persists the secret only after both approvals verify; wipes the
/// derived secret on every failure or cancellation path.
public struct PairingClient: Sendable {
    private let connectionFactory: @Sendable () async throws -> PairingConnection
    private let store: any PairingSecretStore

    public init(connectionFactory: @escaping @Sendable () async throws -> PairingConnection, store: any PairingSecretStore) {
        self.connectionFactory = connectionFactory
        self.store = store
    }

    public func pair(peerId: String, displayName: String,
                     approveSAS: @Sendable (String) async throws -> Bool) async throws -> PairingResult {
        let connection = try await connectionFactory()
        var secretBuffer = Data()
        func wipe() { secretBuffer.resetBytes(in: 0..<secretBuffer.count) }
        do {
            let privateKey = P256.KeyAgreement.PrivateKey()
            let nonce = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            let macHello = PairingHello(role: "mac", peerId: peerId, displayName: displayName,
                                        publicKey: privateKey.publicKey.x963Representation, nonce: nonce)
            try await connection.sendFrame(PairingFraming.encode(macHello.canonicalJSON))

            let androidJSON = try decodeFrame(await connection.receiveFrame())
            let androidHello = try PairingHello.parse(androidJSON)
            guard androidHello.role == "android" else { throw DroidBridgeError.pairingProtocol("expected android hello") }
            let androidPublic = try P256.KeyAgreement.PublicKey(x963Representation: androidHello.publicKey)

            let transcript = PairingCrypto.transcript(macHelloJSON: macHello.canonicalJSON, androidHelloJSON: androidHello.canonicalJSON)
            secretBuffer = try PairingCrypto.deriveSecret(privateKey: privateKey, peerPublicKey: androidPublic,
                                                          macNonce: nonce, androidNonce: androidHello.nonce)
            let sas = PairingCrypto.sas(transcript: transcript)
            let sessionId = PairingCrypto.sessionId(transcript: transcript)

            try Task.checkCancellation()
            guard try await approveSAS(sas) else {
                try? await connection.sendFrame(PairingFraming.encode(PairingApproval(sessionId: sessionId, approved: false, proof: nil).canonicalJSON))
                wipe(); await connection.close()
                throw DroidBridgeError.pairingRejected
            }

            let macProof = PairingCrypto.approvalProof(secret: secretBuffer, role: "mac", transcript: transcript)
            try await connection.sendFrame(PairingFraming.encode(PairingApproval(sessionId: sessionId, approved: true, proof: macProof).canonicalJSON))

            let androidApproval = try PairingApproval.parse(try decodeFrame(await connection.receiveFrame()))
            guard androidApproval.approved, let proof = androidApproval.proof,
                  PairingCrypto.verifyApprovalProof(secret: secretBuffer, role: "android", transcript: transcript, proof: proof) else {
                wipe(); await connection.close()
                throw DroidBridgeError.pairingRejected
            }

            try store.save(secretBuffer, peerId: androidHello.peerId)
            let result = PairingResult(peerId: androidHello.peerId, displayName: androidHello.displayName, secret: secretBuffer)
            await connection.close()
            return result
        } catch {
            wipe()
            await connection.close()
            throw error
        }
    }

    private func decodeFrame(_ frame: Data) throws -> String {
        guard frame.count >= 4 else { throw DroidBridgeError.pairingProtocol("short frame") }
        let length = frame.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= PairingFraming.maxFrame, frame.count == 4 + length else {
            throw DroidBridgeError.pairingProtocol("frame length")
        }
        return String(decoding: frame.suffix(length), as: UTF8.self)
    }
}
