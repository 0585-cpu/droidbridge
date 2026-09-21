package io.droidbridge.security

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.util.Base64
import io.droidbridge.pairing.PairedPeer
import java.nio.ByteBuffer
import java.security.GeneralSecurityException
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-256-GCM envelope in private SharedPreferences. Record: [idLen u8][id][nameLen u8][name][secret 32].
 * Peer id is the AAD, so a swapped id fails decryption. Both keys are written in one committed edit.
 */
class AndroidPairingSecretStore(
    private val prefs: SharedPreferences,
    private val random: SecureRandom = SecureRandom(),
    private val keyProvider: () -> SecretKey,
) : PairingSecretStore {

    override fun load(): PairedPeer? {
        val peerId = prefs.getString(KEY_PEER_ID, null) ?: return null
        val blob = prefs.getString(KEY_BLOB, null) ?: return null
        val bytes = try { Base64.getDecoder().decode(blob) } catch (e: IllegalArgumentException) { return null }
        if (bytes.size <= IV_SIZE) return null
        val plain = try {
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.DECRYPT_MODE, keyProvider(), GCMParameterSpec(TAG_BITS, bytes, 0, IV_SIZE))
            cipher.updateAAD(peerId.toByteArray(Charsets.UTF_8))
            cipher.doFinal(bytes, IV_SIZE, bytes.size - IV_SIZE)
        } catch (e: GeneralSecurityException) {
            return null // tampered or key rotated: treat as unpaired, never as a different peer
        }
        return try { decodeRecord(plain, peerId) } finally { plain.fill(0) }
    }

    override fun replace(peer: PairedPeer) {
        val record = encodeRecord(peer)
        val iv = ByteArray(IV_SIZE).also { random.nextBytes(it) }
        val cipher = Cipher.getInstance(TRANSFORM)
        cipher.init(Cipher.ENCRYPT_MODE, keyProvider(), GCMParameterSpec(TAG_BITS, iv))
        cipher.updateAAD(peer.peerId.toByteArray(Charsets.UTF_8))
        val sealed = try { cipher.doFinal(record) } finally { record.fill(0) }
        val committed = prefs.edit()
            .putString(KEY_PEER_ID, peer.peerId)
            .putString(KEY_BLOB, Base64.getEncoder().encodeToString(iv + sealed))
            .commit()
        if (!committed) throw IllegalStateException("pairing store commit failed")
    }

    override fun clear() {
        prefs.edit().remove(KEY_PEER_ID).remove(KEY_BLOB).commit()
    }

    private fun encodeRecord(peer: PairedPeer): ByteArray {
        val id = peer.peerId.toByteArray(Charsets.UTF_8)
        val name = peer.displayName.toByteArray(Charsets.UTF_8)
        require(id.size <= 255 && name.size <= 255)
        return ByteBuffer.allocate(2 + id.size + name.size + 32)
            .put(id.size.toByte()).put(id).put(name.size.toByte()).put(name).put(peer.secret).array()
    }

    private fun decodeRecord(plain: ByteArray, expectedId: String): PairedPeer? {
        val buf = ByteBuffer.wrap(plain)
        if (buf.remaining() < 1) return null
        val id = ByteArray(buf.get().toInt() and 0xFF).also { if (buf.remaining() < it.size) return null; buf.get(it) }
        if (buf.remaining() < 1) return null
        val name = ByteArray(buf.get().toInt() and 0xFF).also { if (buf.remaining() < it.size) return null; buf.get(it) }
        if (buf.remaining() != 32) return null
        val secret = ByteArray(32).also { buf.get(it) }
        val peerId = String(id, Charsets.UTF_8)
        if (peerId != expectedId) return null
        return PairedPeer(peerId, String(name, Charsets.UTF_8), secret)
    }

    companion object {
        private const val PREFS_NAME = "io.droidbridge.pairing"
        private const val KEY_PEER_ID = "peer.id"
        private const val KEY_BLOB = "peer.v1"
        private const val KEY_ALIAS = "io.droidbridge.pairing.storage.v1"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val IV_SIZE = 12
        private const val TAG_BITS = 128

        fun create(context: Context): AndroidPairingSecretStore =
            AndroidPairingSecretStore(context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE), keyProvider = ::keystoreKey)

        /** AES-256-GCM key living in AndroidKeyStore; created on first use, never exported. */
        private fun keystoreKey(): SecretKey {
            val keyStore = KeyStore.getInstance("AndroidKeyStore").also { it.load(null) }
            (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
            val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            generator.init(
                KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .setKeySize(256)
                    .setRandomizedEncryptionRequired(false) // we supply a fresh random IV per record
                    .build(),
            )
            return generator.generateKey()
        }
    }
}
