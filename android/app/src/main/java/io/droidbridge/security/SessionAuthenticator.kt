package io.droidbridge.security

import io.droidbridge.protocol.DbpCodec
import io.droidbridge.protocol.DbpHeader
import io.droidbridge.protocol.DbpHmac
import io.droidbridge.protocol.DbpMessageType
import io.droidbridge.protocol.DbpProtocolException
import java.security.MessageDigest
import java.security.SecureRandom
import kotlin.math.abs

/** Authentication failure. Reason is for local diagnostics only and is never sent to the peer. */
class DbpAuthenticationException(message: String) : Exception(message)

class SessionAuthenticator(
    private val secretProvider: () -> ByteArray?,
    private val replayCache: NonceReplayCache,
    private val clock: EpochClock,
    private val random: SecureRandom = SecureRandom(),
) {
    fun acceptHello(header: DbpHeader, payload: ByteArray): AuthenticatedSession {
        if (header.type != DbpMessageType.HELLO) throw DbpProtocolException("expected HELLO")
        if (header.flags != 0) throw DbpProtocolException("flags")
        if (payload.isNotEmpty()) throw DbpProtocolException("HELLO payload")
        if (header.serverNonce != 0L) throw DbpProtocolException("server nonce in HELLO")
        val secret = secretProvider() ?: throw DbpAuthenticationException("no paired peer")
        verify(secret, header, payload)
        if (header.clientNonce == 0L) throw DbpAuthenticationException("zero client nonce")
        if (!replayCache.checkAndAdd(header.clientNonce)) throw DbpAuthenticationException("nonce replay")
        var serverNonce = 0L
        while (serverNonce == 0L) serverNonce = random.nextLong()
        return AuthenticatedSession(secret, header.clientNonce, serverNonce, clock)
    }

    companion object {
        const val TIMESTAMP_TOLERANCE_SECONDS = 120L

        internal fun verify(secret: ByteArray, header: DbpHeader, payload: ByteArray) {
            val expected = DbpHmac.compute(secret, header.copy(hmac = ByteArray(DbpCodec.HMAC_SIZE)), payload)
            if (!MessageDigest.isEqual(expected, header.hmac)) throw DbpAuthenticationException("hmac")
        }
    }

    private fun verify(secret: ByteArray, header: DbpHeader, payload: ByteArray) {
        Companion.verify(secret, header, payload)
        if (abs(clock.epochSeconds() - header.unixTime) > TIMESTAMP_TOLERANCE_SECONDS) throw DbpAuthenticationException("timestamp")
    }
}

/** Connection-scoped credentials: the fixed (clientNonce, serverNonce) pair negotiated by HELLO/HELLO_OK. */
class AuthenticatedSession internal constructor(
    private val secret: ByteArray,
    val clientNonce: Long,
    val serverNonce: Long,
    private val clock: EpochClock,
) {
    fun verifyFollowup(header: DbpHeader, payload: ByteArray) {
        if (header.flags != 0) throw DbpProtocolException("flags")
        if (header.clientNonce != clientNonce || header.serverNonce != serverNonce) throw DbpAuthenticationException("nonce pair")
        SessionAuthenticator.verify(secret, header, payload)
        if (abs(clock.epochSeconds() - header.unixTime) > SessionAuthenticator.TIMESTAMP_TOLERANCE_SECONDS) throw DbpAuthenticationException("timestamp")
    }

    /** Builds a complete signed frame (header + payload) for a reply on this connection. */
    fun sign(type: DbpMessageType, payload: ByteArray): ByteArray {
        val header = DbpHeader(type, 0, clientNonce, serverNonce, clock.epochSeconds(), ByteArray(DbpCodec.HMAC_SIZE))
        return DbpCodec.encodeHeader(header, DbpHmac.compute(secret, header, payload)) + payload
    }
}
