package io.droidbridge.protocol

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertIs

@OptIn(ExperimentalStdlibApi::class)
class DbpCodecTest {
    private val document = TestJson.loadResource("dbp-v1.json")
    private val vectors = (document["vectors"] as List<*>).associate { v ->
        v as Map<*, *>
        (v["name"] as String) to v
    }

    private fun fixture(name: String): Map<*, *> = vectors.getValue(name)
    private fun packet(name: String): ByteArray = (fixture(name)["packet_hex"] as String).hexToByteArray()

    @Test
    fun `fixture document matches the codec constants`() {
        assertEquals(64L, document["header_size"])
        assertEquals(DbpCodec.HEADER_SIZE, 64)
        val types = document["message_types"] as Map<*, *>
        for ((name, code) in types) assertEquals((code as Long).toInt(), DbpMessageType.valueOf(name as String).code, name)
        val errors = document["error_codes"] as Map<*, *>
        for ((name, code) in errors) assertEquals((code as Long).toInt(), DbpErrorCode.valueOf(name as String).code, name)
        assertEquals(10, vectors.size)
    }

    @Test
    fun `every fixture header decodes and re-encodes byte for byte`() {
        for ((name, v) in vectors) {
            val bytes = packet(name)
            val header = DbpCodec.decodeHeader(bytes)
            assertEquals((v["message_type"] as Long).toInt(), header.type.code, name)
            assertEquals(0, header.flags)
            assertEquals((v["client_nonce"] as String).hexToLong(), header.clientNonce, name)
            assertEquals((v["server_nonce"] as String).hexToLong(), header.serverNonce, name)
            assertEquals(v["unix_time"] as Long, header.unixTime, name)
            assertContentEquals((v["hmac_hex"] as String).hexToByteArray(), header.hmac, name)
            assertContentEquals(bytes.copyOf(64), DbpCodec.encodeHeader(header, header.hmac), name)
        }
    }

    @Test
    fun `domain OPEN_TCP fixture decodes byte for byte`() {
        val message = DbpCodec.decode(packet("open_domain_443"))
        assertEquals(DbpMessageType.OPEN_TCP, message.header.type)
        assertEquals(OpenDestination.Domain("example.com", 443), message.payload)
        assertContentEquals(packet("open_domain_443").copyOfRange(64, 79), DbpCodec.encodeOpenTcp(message.payload as OpenDestination))
    }

    @Test
    fun `ipv4 OPEN_TCP fixture decodes`() {
        val message = DbpCodec.decode(packet("open_ipv4_443"))
        val dest = assertIs<OpenDestination.Ipv4>(message.payload)
        assertContentEquals(byteArrayOf(93, 184.toByte(), 216.toByte(), 34), dest.address)
        assertEquals(443, dest.port)
        assertContentEquals(packet("open_ipv4_443").copyOfRange(64, 72), DbpCodec.encodeOpenTcp(dest))
    }

    @Test
    fun `typed payloads decode for every other fixture`() {
        assertEquals(DbpPayload.Empty, DbpCodec.decode(packet("hello")).payload)
        assertEquals(DbpPayload.Empty, DbpCodec.decode(packet("hello_ok")).payload)
        assertEquals(DbpPayload.Empty, DbpCodec.decode(packet("open_ok")).payload)
        assertEquals(DbpPayload.Empty, DbpCodec.decode(packet("health")).payload)
        assertEquals(DbpPayload.Error(DbpErrorCode.POLICY_DENIED), DbpCodec.decode(packet("open_error_policy_denied")).payload)
        val dns = assertIs<DbpPayload.Dns>(DbpCodec.decode(packet("dns_query")).payload)
        assertEquals(31 - 2, dns.packet.size)
        val health = assertIs<DbpPayload.Health>(DbpCodec.decode(packet("health_response_ready")).payload)
        assertEquals(DbpPayload.Health(HealthStatus.READY, 3, 128, 1_048_576, 8_388_608, "TestCarrier"), health)
    }

    @Test
    fun `encoders reproduce fixture payloads`() {
        assertContentEquals(packet("open_error_policy_denied").copyOfRange(64, 65), DbpCodec.encodeError(DbpErrorCode.POLICY_DENIED))
        val health = DbpPayload.Health(HealthStatus.READY, 3, 128, 1_048_576, 8_388_608, "TestCarrier")
        assertContentEquals(packet("health_response_ready").copyOfRange(64, 97), DbpCodec.encodeHealth(health))
        val dnsPacket = packet("dns_query").copyOfRange(66, 64 + 31)
        assertContentEquals(packet("dns_query").copyOfRange(64, 64 + 31), DbpCodec.encodeDns(dnsPacket))
    }

    @Test
    fun `header rejections`() {
        val good = packet("hello")
        assertFailsWith<DbpProtocolException> { DbpCodec.decodeHeader(good.copyOf(63)) }
        assertFailsWith<DbpProtocolException> { DbpCodec.decodeHeader(good.copyOf().also { it[0] = 'X'.code.toByte() }) }
        assertFailsWith<DbpProtocolException> { DbpCodec.decodeHeader(good.copyOf().also { it[5] = 1 }) }          // flags
        assertFailsWith<DbpProtocolException> { DbpCodec.decodeHeader(good.copyOf().also { it[7] = 63 }) }         // header length
        assertFailsWith<DbpProtocolException> { DbpCodec.decodeHeader(good.copyOf().also { it[6] = 1 }) }          // header length 0x0140
        val known = DbpMessageType.entries.map { it.code }.toSet()
        for (t in 0..255) {
            val bytes = good.copyOf().also { it[4] = t.toByte() }
            if (t in known) DbpCodec.decodeHeader(bytes) else assertFailsWith<DbpProtocolException>("type $t") { DbpCodec.decodeHeader(bytes) }
        }
    }

    @Test
    fun `OPEN_TCP rejections`() {
        fun bad(vararg b: Int) = assertFailsWith<DbpProtocolException> { DbpCodec.decodeOpenTcp(b.map { it.toByte() }.toByteArray()) }
        bad(1, 0, 0, 4, 93, 184, 216, 34)            // zero port
        bad(2, 1, 187, 4, 93, 184, 216, 34)          // unknown type
        bad(0, 1, 187, 4, 93, 184, 216, 34)
        bad(1, 1, 187, 3, 93, 184, 216)              // ipv4 length
        bad(3, 1, 187, 0)                            // empty domain
        bad(3, 1, 187, 11, 'e'.code, 'x'.code)       // truncated
        bad(1, 1, 187, 4, 93, 184, 216, 34, 0)       // trailing byte
        bad(1, 1, 187)                               // shorter than prefix
        val long = ByteArray(4 + 254) { 'a'.code.toByte() }.also { it[0] = 3; it[1] = 1; it[2] = 187.toByte(); it[3] = 254.toByte() }
        assertFailsWith<DbpProtocolException> { DbpCodec.decodeOpenTcp(long) }
        val max = ByteArray(4 + 253) { 'a'.code.toByte() }.also { it[0] = 3; it[1] = 1; it[2] = 187.toByte(); it[3] = 253.toByte() }
        assertEquals(253, (DbpCodec.decodeOpenTcp(max) as OpenDestination.Domain).host.length)
    }

    @Test
    fun `payload length is derived from the type specific prefix and capped`() {
        assertEquals(0, DbpCodec.payloadPrefixLength(DbpMessageType.HELLO))
        assertEquals(1, DbpCodec.payloadPrefixLength(DbpMessageType.OPEN_ERROR))
        assertEquals(4, DbpCodec.payloadPrefixLength(DbpMessageType.OPEN_TCP))
        assertEquals(2, DbpCodec.payloadPrefixLength(DbpMessageType.DNS_QUERY))
        assertEquals(22, DbpCodec.payloadPrefixLength(DbpMessageType.HEALTH_RESPONSE))
        assertEquals(11, DbpCodec.payloadRemaining(DbpMessageType.OPEN_TCP, byteArrayOf(3, 1, 187.toByte(), 11)))
        assertEquals(4096, DbpCodec.payloadRemaining(DbpMessageType.DNS_QUERY, byteArrayOf(0x10, 0)))
        assertFailsWith<DbpProtocolException> { DbpCodec.payloadRemaining(DbpMessageType.DNS_QUERY, byteArrayOf(0x10, 1)) }  // 4097
        assertFailsWith<DbpProtocolException> { DbpCodec.payloadRemaining(DbpMessageType.DNS_QUERY, byteArrayOf(0, 11)) }    // < 12
        assertFailsWith<DbpProtocolException> { DbpCodec.payloadRemaining(DbpMessageType.HEALTH_RESPONSE, ByteArray(22).also { it[21] = 64 }) }
    }

    @Test
    fun `health payload validation`() {
        assertFailsWith<DbpProtocolException> { DbpCodec.encodeHealth(DbpPayload.Health(HealthStatus.READY, 5, 4, 0, 0, "x")) }
        assertFailsWith<DbpProtocolException> { DbpCodec.encodeHealth(DbpPayload.Health(HealthStatus.READY, 0, 257, 0, 0, "x")) }
        assertFailsWith<DbpProtocolException> { DbpCodec.encodeHealth(DbpPayload.Health(HealthStatus.READY, 0, 1, 0, 0, "x".repeat(64))) }
        val invalidUtf8 = ByteArray(22).also { it[0] = 1; it[3] = 1; it[21] = 1 } + byteArrayOf(0xFF.toByte())
        assertFailsWith<DbpProtocolException> { DbpCodec.decodePayload(DbpMessageType.HEALTH_RESPONSE, invalidUtf8) }
    }
}
