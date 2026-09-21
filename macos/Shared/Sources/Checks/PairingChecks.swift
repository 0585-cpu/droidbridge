import DroidBridgeShared
import CryptoKit
import Foundation

private func hexData(_ s: String) -> Data {
    var data = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); data.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return data
}

/// A fake Android endpoint backed by a fixed key; mirrors the coordinator so pair() can complete.
final class FakeAndroidConnection: PairingConnection, @unchecked Sendable {
    private let androidPriv: P256.KeyAgreement.PrivateKey
    private let peerId: String
    private let displayName: String
    private let nonce: Data
    private let tamperProof: Bool
    private let stallAfterHello: Bool
    private let lock = NSLock()
    private var outbox: [Data] = []
    private var macHelloJSON: String?
    private var secret: Data?
    private var transcript: Data?
    private var continuation: CheckedContinuation<Data, Error>?

    init(androidPriv: P256.KeyAgreement.PrivateKey, peerId: String = "android-1", displayName: String = "Pixel",
         nonce: Data, tamperProof: Bool = false, stallAfterHello: Bool = false) {
        self.androidPriv = androidPriv; self.peerId = peerId; self.displayName = displayName
        self.nonce = nonce; self.tamperProof = tamperProof; self.stallAfterHello = stallAfterHello
    }

    func sendFrame(_ data: Data) async throws {
        let json = String(decoding: data.suffix(data.count - 4), as: UTF8.self)
        if json.contains("\"role\":\"mac\"") {
            macHelloJSON = json
            let mac = try PairingHello.parse(json)
            let androidHello = PairingHello(role: "android", peerId: peerId, displayName: displayName,
                                            publicKey: androidPriv.publicKey.x963Representation, nonce: nonce)
            let tr = PairingCrypto.transcript(macHelloJSON: json, androidHelloJSON: androidHello.canonicalJSON)
            transcript = tr
            secret = try PairingCrypto.deriveSecret(privateKey: androidPriv,
                                                    peerPublicKey: try P256.KeyAgreement.PublicKey(x963Representation: mac.publicKey),
                                                    macNonce: mac.nonce, androidNonce: nonce)
            enqueue(try PairingFraming.encode(androidHello.canonicalJSON))
        } else {
            // mac approval arrived; respond with android approval unless stalling
            guard !stallAfterHello, let secret, let transcript else { return }
            var proof = PairingCrypto.approvalProof(secret: secret, role: "android", transcript: transcript)
            if tamperProof { proof = Data(repeating: 0, count: 32) }
            let sessionId = PairingCrypto.sessionId(transcript: transcript)
            enqueue(try PairingFraming.encode(PairingApproval(sessionId: sessionId, approved: true, proof: proof).canonicalJSON))
        }
    }

    func receiveFrame() async throws -> Data {
        if let frame = dequeue() { return frame }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            self.lock.withLock { self.continuation = cont }
        }
    }

    func close() async {}

    private func enqueue(_ frame: Data) {
        lock.lock(); let cont = continuation; continuation = nil
        if cont == nil { outbox.append(frame) }
        lock.unlock()
        cont?.resume(returning: frame)
    }
    private func dequeue() -> Data? { lock.withLock { outbox.isEmpty ? nil : outbox.removeFirst() } }
}

func runPairingChecks(_ r: CheckRunner) async {
    // --- fixed-vector parity with tools/pairing_probe.py ---
    let macPriv = try! P256.KeyAgreement.PrivateKey(rawRepresentation: hexData("0011111111111111111111111111111111111111111111111111111111111111"))
    let andPubX963 = hexData("049352cff3b5e19b13bba05bf563654119765ebd59397bcd4095cfe45bba9de8165abf89c2c81153998d7e680dbace4162598fc1f0da132d9561aeebb7517e94a6")
    let macNonce = hexData("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
    let andNonce = hexData("6465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f80818283")
    let macHello = PairingHello(role: "mac", peerId: "mac-1", displayName: "MacBook", publicKey: macPriv.publicKey.x963Representation, nonce: macNonce)
    let andHello = PairingHello(role: "android", peerId: "android-1", displayName: "Pixel", publicKey: andPubX963, nonce: andNonce)
    r.check(macHello.canonicalJSON == "{\"displayName\":\"MacBook\",\"nonce\":\"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=\",\"peerId\":\"mac-1\",\"publicKey\":\"BBScWNe4D+dRCv1Ro7sJzo0aqjN0BEZ+B20prIZf+dQqQfpvJOS2iYoL7IOenF3mhAVw7ZY6/zQfid39fa9snOM=\",\"role\":\"mac\",\"version\":1}", "mac hello canonical JSON matches python")
    let transcript = PairingCrypto.transcript(macHelloJSON: macHello.canonicalJSON, androidHelloJSON: andHello.canonicalJSON)
    let secret = try! PairingCrypto.deriveSecret(privateKey: macPriv, peerPublicKey: try! P256.KeyAgreement.PublicKey(x963Representation: andPubX963), macNonce: macNonce, androidNonce: andNonce)
    r.check(secret.map { String(format: "%02x", $0) }.joined() == "30dff7f06fb88cd9f0215b98f7c177bd71e1411dd2b5ee38206f962c714f5bea", "derived secret matches python")
    r.check(PairingCrypto.sas(transcript: transcript) == "771685", "SAS matches python")
    r.check(PairingCrypto.sessionId(transcript: transcript) == "589e55e5868097157da19c21d5de6f0e", "session id matches python")
    r.check(PairingCrypto.approvalProof(secret: secret, role: "mac", transcript: transcript).map { String(format: "%02x", $0) }.joined() == "4e6d36b69597deaf1066d7ad275dc42974df3987c3072c1f46c12de8d9a96c50", "mac proof matches python")
    r.check(PairingCrypto.verifyApprovalProof(secret: secret, role: "android", transcript: transcript, proof: hexData("33bd1828d80c42cfb31f11698caa8c7f4c9988398310580b9c4cfd083a573e34")), "verifies android proof from python")

    // --- full pair() success ---
    let androidPriv = P256.KeyAgreement.PrivateKey()
    let successStore = InMemoryPairingSecretStore()
    let successClient = PairingClient(connectionFactory: { FakeAndroidConnection(androidPriv: androidPriv, nonce: Data((0..<32).map { _ in 7 })) }, store: successStore)
    do {
        let result = try await successClient.pair(peerId: "mac-1", displayName: "MacBook") { _ in true }
        r.check(result.peerId == "android-1" && result.secret.count == 32, "pair() returns android peer + 32-byte secret")
        r.check(successStore.saveCount == 1, "pair() persists secret once")
    } catch { r.check(false, "pair() success threw: \(error)") }

    // --- rejection by mac user ---
    let rejectStore = InMemoryPairingSecretStore()
    let rejectClient = PairingClient(connectionFactory: { FakeAndroidConnection(androidPriv: P256.KeyAgreement.PrivateKey(), nonce: Data(count: 32)) }, store: rejectStore)
    do { _ = try await rejectClient.pair(peerId: "m", displayName: "M") { _ in false }; r.check(false, "reject throws") }
    catch { r.check(rejectStore.saveCount == 0, "rejection persists nothing") }

    // --- tampered android proof ---
    let tamperStore = InMemoryPairingSecretStore()
    let tamperClient = PairingClient(connectionFactory: { FakeAndroidConnection(androidPriv: P256.KeyAgreement.PrivateKey(), nonce: Data(count: 32), tamperProof: true) }, store: tamperStore)
    do { _ = try await tamperClient.pair(peerId: "m", displayName: "M") { _ in true }; r.check(false, "tampered proof throws") }
    catch { r.check(tamperStore.saveCount == 0, "tampered proof persists nothing") }

    // --- cancellation before approval ---
    let cancelStore = InMemoryPairingSecretStore()
    let cancelClient = PairingClient(connectionFactory: { FakeAndroidConnection(androidPriv: P256.KeyAgreement.PrivateKey(), nonce: Data(count: 32), stallAfterHello: true) }, store: cancelStore)
    let task = Task { try await cancelClient.pair(peerId: "m", displayName: "M") { _ in try await Task.sleep(for: .seconds(3600)); return true } }
    try? await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do { _ = try await task.value; r.check(false, "cancelled pair throws") } catch { r.check(cancelStore.saveCount == 0, "cancellation persists nothing") }

    // --- frame too large ---
    do { _ = try PairingFraming.encode(String(repeating: "x", count: 8193)); r.check(false, "oversize frame throws") }
    catch { r.check(true, "oversize frame throws") }

    r.finish("pairing")
}
