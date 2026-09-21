package io.droidbridge.security

import io.droidbridge.protocol.DbpCodec
import io.droidbridge.protocol.DbpHeader
import io.droidbridge.protocol.DbpHmac
import io.droidbridge.protocol.DbpMessageType
import io.droidbridge.protocol.DbpProtocolException
import java.security.SecureRandom
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotEquals
import kotlin.test.assertTrue

class MutableClock(var now: Long) : EpochClock {
    override fun epochSeconds(): Long = now
}

class SessionAuthenticatorTest {
    private val secret = ByteArray(32).also { it[31] = 1 }
    private val clock = MutableClock(1_700_000_000)
    private val cache = NonceReplayCache(maxEntries = 1024, ttlSeconds = 300, clock = clock)
    private val authenticator = SessionAuthenticator({ secret }, cache, clock, SecureRandom())

    private fun signed(type: DbpMessageType, clientNonce: Long, serverNonce: Long = 0, timestamp: Long = clock.now,
                       payload: ByteArray = ByteArray(0), key: ByteArray = secret, flags: Int = 0): Pair<DbpHeader, ByteArray> {
        val unsigned = DbpHeader(type, flags, clientNonce, serverNonce, timestamp, ByteArray(32))
        val mac = DbpHmac.compute(key, unsigned, payload)
        return unsigned.copy(hmac = mac) to payload
    }

    private fun signedHello(clientNonce: Long, timestamp: Long = clock.now) = signed(DbpMessageType.HELLO, clientNonce, timestamp = timestamp)
    private fun signedHealth(clientNonce: Long, serverNonce: Long) = signed(DbpMessageType.HEALTH, clientNonce, serverNonce)

    @Test
    fun `nonce may continue in the authenticated connection but not in a new connection`() {
        val hello = signedHello(clientNonce = 7)
        val session = authenticator.acceptHello(hello.first, hello.second)
        val health = signedHealth(clientNonce = 7, serverNonce = session.serverNonce)
        session.verifyFollowup(health.first, health.second)
        session.verifyFollowup(health.first, health.second) // same connection may keep using the pair
        assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(hello.first, hello.second) }
    }

    @Test
    fun `server nonce is random non-zero and signed replies verify with the shared secret`() {
        val s1 = authenticator.acceptHello(*signedHello(1).toArray())
        val s2 = authenticator.acceptHello(*signedHello(2).toArray())
        assertNotEquals(0L, s1.serverNonce)
        assertNotEquals(s1.serverNonce, s2.serverNonce)
        val frame = s1.sign(DbpMessageType.HELLO_OK, ByteArray(0))
        val header = DbpCodec.decodeHeader(frame)
        assertEquals(1L, header.clientNonce)
        assertEquals(s1.serverNonce, header.serverNonce)
        assertContentEquals(DbpHmac.compute(secret, header.copy(hmac = ByteArray(32)), ByteArray(0)), header.hmac)
    }

    @Test
    fun `timestamp tolerance is exactly 120 seconds`() {
        authenticator.acceptHello(*signedHello(10, timestamp = clock.now - 120).toArray())
        authenticator.acceptHello(*signedHello(11, timestamp = clock.now + 120).toArray())
        assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(*signedHello(12, timestamp = clock.now - 121).toArray()) }
        assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(*signedHello(13, timestamp = clock.now + 121).toArray()) }
    }

    @Test
    fun `wrong hmac, wrong secret and missing secret are rejected`() {
        assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(*signedHello(20).let { it.first.copy(hmac = ByteArray(32)) to it.second }.toArray()) }
        assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(*signed(DbpMessageType.HELLO, 21, key = ByteArray(32)).toArray()) }
        val unpaired = SessionAuthenticator({ null }, cache, clock)
        assertFailsWith<DbpAuthenticationException> { unpaired.acceptHello(*signedHello(22).toArray()) }
        assertFalse(cache.contains(20)); assertFalse(cache.contains(21)); assertFalse(cache.contains(22))
    }

    @Test
    fun `hello structure rules`() {
        assertFailsWith<DbpProtocolException> { authenticator.acceptHello(*signed(DbpMessageType.HEALTH, 30).toArray()) }             // not HELLO
        assertFailsWith<DbpProtocolException> { authenticator.acceptHello(*signed(DbpMessageType.HELLO, 31, flags = 1).toArray()) }   // flags
        assertFailsWith<DbpProtocolException> { authenticator.acceptHello(*signed(DbpMessageType.HELLO, 32, payload = byteArrayOf(1)).toArray()) }
        assertFailsWith<DbpProtocolException> { authenticator.acceptHello(*signed(DbpMessageType.HELLO, 33, serverNonce = 5).toArray()) }
        assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(*signed(DbpMessageType.HELLO, 0).toArray()) }          // zero nonce
    }

    @Test
    fun `followup requires the exact nonce pair and valid hmac`() {
        val session = authenticator.acceptHello(*signedHello(40).toArray())
        assertFailsWith<DbpAuthenticationException> { session.verifyFollowup(*signedHealth(41, session.serverNonce).toArray()) }
        assertFailsWith<DbpAuthenticationException> { session.verifyFollowup(*signedHealth(40, session.serverNonce + 1).toArray()) }
        assertFailsWith<DbpAuthenticationException> { session.verifyFollowup(*signed(DbpMessageType.HEALTH, 40, session.serverNonce, key = ByteArray(32)).toArray()) }
        assertFailsWith<DbpProtocolException> { session.verifyFollowup(*signed(DbpMessageType.HEALTH, 40, session.serverNonce, flags = 1).toArray()) }
        assertFailsWith<DbpAuthenticationException> { session.verifyFollowup(*signed(DbpMessageType.HEALTH, 40, session.serverNonce, timestamp = clock.now + 121).toArray()) }
    }

    @Test
    fun `replay cache evicts oldest at 1024 and expires after ttl`() {
        for (n in 1L..1024L) assertTrue(cache.checkAndAdd(n))
        assertFalse(cache.checkAndAdd(1))
        assertTrue(cache.checkAndAdd(1025))     // evicts nonce 1
        assertTrue(cache.checkAndAdd(1))        // 1 forgotten after eviction
        assertFalse(cache.checkAndAdd(1025))
        clock.now += 301
        assertTrue(cache.checkAndAdd(1025))     // expired
    }

    private fun Pair<DbpHeader, ByteArray>.toArray() = arrayOf(first, second)
    private fun SessionAuthenticator.acceptHello(vararg parts: Any) = acceptHello(parts[0] as DbpHeader, parts[1] as ByteArray)
    private fun AuthenticatedSession.verifyFollowup(vararg parts: Any) = verifyFollowup(parts[0] as DbpHeader, parts[1] as ByteArray)
}
