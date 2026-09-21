package io.droidbridge.pairing

import io.droidbridge.util.Json
import java.math.BigInteger
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import java.util.Base64
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

class PairingException(message: String) : Exception(message)

/** One side's hello. `publicKey` is X9.63 uncompressed (65 bytes), `nonce` is 32 random bytes. */
data class PairingHello(
    val role: String,
    val peerId: String,
    val displayName: String,
    val publicKey: ByteArray,
    val nonce: ByteArray,
) {
    init {
        if (role != "mac" && role != "android") throw PairingException("role")
        if (publicKey.size != 65) throw PairingException("public key length")
        if (nonce.size != 32) throw PairingException("nonce length")
        if (peerId.isEmpty() || peerId.length > 64) throw PairingException("peer id")
        if (displayName.length > 64) throw PairingException("display name")
    }

    /** Sorted keys, no whitespace: the exact bytes both sides hash into the transcript. */
    fun canonicalJson(): String = Json.encode(
        mapOf(
            "version" to 1L, "role" to role, "peerId" to peerId, "displayName" to displayName,
            "publicKey" to Base64.getEncoder().encodeToString(publicKey),
            "nonce" to Base64.getEncoder().encodeToString(nonce),
        ),
    )

    override fun equals(other: Any?): Boolean = other is PairingHello && canonicalJson() == other.canonicalJson()
    override fun hashCode(): Int = canonicalJson().hashCode()

    companion object {
        fun parse(json: String): PairingHello {
            val map = try { Json.parseObject(json) } catch (e: IllegalArgumentException) { throw PairingException("hello json") }
            if (map["version"] != 1L) throw PairingException("version")
            return try {
                PairingHello(
                    role = map["role"] as? String ?: throw PairingException("role"),
                    peerId = map["peerId"] as? String ?: throw PairingException("peerId"),
                    displayName = map["displayName"] as? String ?: "",
                    publicKey = Base64.getDecoder().decode(map["publicKey"] as? String ?: throw PairingException("publicKey")),
                    nonce = Base64.getDecoder().decode(map["nonce"] as? String ?: throw PairingException("nonce")),
                )
            } catch (e: IllegalArgumentException) {
                throw PairingException("hello base64")
            }
        }
    }
}

data class PairingApproval(val sessionId: String, val approved: Boolean, val proof: ByteArray?) {
    fun toJson(): String = Json.encode(
        mapOf("sessionId" to sessionId, "approved" to approved, "proof" to proof?.let { Base64.getEncoder().encodeToString(it) }),
    )

    companion object {
        fun parse(json: String): PairingApproval {
            val map = try { Json.parseObject(json) } catch (e: IllegalArgumentException) { throw PairingException("approval json") }
            return PairingApproval(
                sessionId = map["sessionId"] as? String ?: throw PairingException("sessionId"),
                approved = map["approved"] as? Boolean ?: throw PairingException("approved"),
                proof = (map["proof"] as? String)?.let {
                    try { Base64.getDecoder().decode(it) } catch (e: IllegalArgumentException) { throw PairingException("proof base64") }
                },
            )
        }
    }
}

class PairingTranscript private constructor(val bytes: ByteArray, val macNonce: ByteArray, val androidNonce: ByteArray) {
    val hash: ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)
    val salt: ByteArray get() = macNonce + androidNonce

    /** First 16 bytes of the transcript hash, hex: both sides can compute it without another round trip. */
    val sessionId: String get() = hash.copyOf(16).joinToString("") { "%02x".format(it) }

    /** Six-digit Short Authentication String from the first four hash bytes. */
    val sas: String
        get() {
            val value = ((hash[0].toLong() and 0xFF) shl 24) or ((hash[1].toLong() and 0xFF) shl 16) or
                ((hash[2].toLong() and 0xFF) shl 8) or (hash[3].toLong() and 0xFF)
            return "%06d".format(value % 1_000_000)
        }

    companion object {
        private val PREFIX = "DROIDBRIDGE-PAIR-1".toByteArray(Charsets.UTF_8)

        fun create(macHello: PairingHello, androidHello: PairingHello): PairingTranscript {
            if (macHello.role != "mac" || androidHello.role != "android") throw PairingException("roles")
            val bytes = PREFIX + macHello.canonicalJson().toByteArray(Charsets.UTF_8) + androidHello.canonicalJson().toByteArray(Charsets.UTF_8)
            return PairingTranscript(bytes, macHello.nonce, androidHello.nonce)
        }
    }
}

class PairingResult(val secret: ByteArray, val sas: String)

object PairingProtocol {
    private const val CURVE = "secp256r1"
    private val INFO = "DroidBridge DBP/1 Pairing".toByteArray(Charsets.UTF_8)
    private val params: ECParameterSpec = AlgorithmParameters.getInstance("EC")
        .also { it.init(ECGenParameterSpec(CURVE)) }
        .getParameterSpec(ECParameterSpec::class.java)

    fun generateKeyPair(random: SecureRandom = SecureRandom()): KeyPair =
        KeyPairGenerator.getInstance("EC").also { it.initialize(ECGenParameterSpec(CURVE), random) }.generateKeyPair()

    /** X9.63 uncompressed: 0x04 || X(32) || Y(32). */
    fun encodePublicKey(key: PublicKey): ByteArray {
        val point = (key as ECPublicKey).w
        return byteArrayOf(0x04) + fixed32(point.affineX) + fixed32(point.affineY)
    }

    fun decodePublicKey(bytes: ByteArray): ECPublicKey {
        if (bytes.size != 65 || bytes[0] != 0x04.toByte()) throw PairingException("public key encoding")
        val x = BigInteger(1, bytes.copyOfRange(1, 33))
        val y = BigInteger(1, bytes.copyOfRange(33, 65))
        requireOnCurve(x, y)
        return try {
            KeyFactory.getInstance("EC").generatePublic(ECPublicKeySpec(ECPoint(x, y), params)) as ECPublicKey
        } catch (e: java.security.GeneralSecurityException) {
            throw PairingException("public key")
        }
    }

    fun derive(privateKey: PrivateKey, peerPublicKey: PublicKey, transcript: PairingTranscript): PairingResult {
        val agreement = KeyAgreement.getInstance("ECDH")
        agreement.init(privateKey)
        agreement.doPhase(peerPublicKey, true)
        val shared = agreement.generateSecret()
        val secret = try {
            hkdfSha256(ikm = shared, salt = transcript.salt, info = INFO, length = 32)
        } finally {
            shared.fill(0)
        }
        return PairingResult(secret, transcript.sas)
    }

    /** HMAC(secret, role || 0x00 || SHA-256(transcript)). */
    fun approvalProof(secret: ByteArray, role: String, transcript: PairingTranscript): ByteArray =
        hmac(secret, role.toByteArray(Charsets.UTF_8) + byteArrayOf(0) + transcript.hash)

    fun verifyApprovalProof(secret: ByteArray, role: String, transcript: PairingTranscript, proof: ByteArray): Boolean =
        MessageDigest.isEqual(approvalProof(secret, role, transcript), proof)

    private fun requireOnCurve(x: BigInteger, y: BigInteger) {
        val p = (params.curve.field as java.security.spec.ECFieldFp).p
        if (x.signum() <= 0 || y.signum() <= 0 || x >= p || y >= p) throw PairingException("point range")
        val lhs = y.multiply(y).mod(p)
        val rhs = x.pow(3).add(params.curve.a.multiply(x)).add(params.curve.b).mod(p)
        if (lhs != rhs) throw PairingException("point not on curve")
    }

    private fun fixed32(v: BigInteger): ByteArray {
        val raw = v.toByteArray()
        return when {
            raw.size == 32 -> raw
            raw.size > 32 -> raw.copyOfRange(raw.size - 32, raw.size)
            else -> ByteArray(32 - raw.size) + raw
        }
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    private fun hkdfSha256(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(salt, ikm)
        val out = ByteArray(length)
        var previous = ByteArray(0)
        var offset = 0
        var counter = 1
        while (offset < length) {
            previous = hmac(prk, previous + info + byteArrayOf(counter.toByte()))
            val n = minOf(previous.size, length - offset)
            System.arraycopy(previous, 0, out, offset, n)
            offset += n
            counter++
        }
        prk.fill(0)
        return out
    }
}
