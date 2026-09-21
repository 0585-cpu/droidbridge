package io.droidbridge.protocol

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/** DBP/1 wire codec. Structure only; authentication lives in [io.droidbridge.security]. */
object DbpCodec {
    const val HEADER_SIZE = 64
    const val HMAC_SIZE = 32
    const val MAX_CONTROL_PAYLOAD = 4096
    const val MAX_DOMAIN_LENGTH = 253
    const val DNS_MIN = 12
    const val MAX_SESSIONS = 256
    private const val HEALTH_PREFIX = 22
    private const val MAX_CARRIER = 63
    private val MAGIC = byteArrayOf('D'.code.toByte(), 'B'.code.toByte(), 'P'.code.toByte(), '1'.code.toByte())

    fun decodeHeader(bytes: ByteArray): DbpHeader {
        if (bytes.size < HEADER_SIZE) throw DbpProtocolException("truncated header")
        val buf = ByteBuffer.wrap(bytes.copyOf(HEADER_SIZE)).order(ByteOrder.BIG_ENDIAN)
        val magic = ByteArray(4).also { buf.get(it) }
        if (!magic.contentEquals(MAGIC)) throw DbpProtocolException("bad magic")
        val typeCode = buf.get().toInt() and 0xFF
        val flags = buf.get().toInt() and 0xFF
        val headerLength = buf.short.toInt() and 0xFFFF
        if (headerLength != HEADER_SIZE) throw DbpProtocolException("bad header length")
        val type = DbpMessageType.fromCode(typeCode)
        if (flags != 0) throw DbpProtocolException("flags must be zero")
        val clientNonce = buf.long
        val serverNonce = buf.long
        val unixTime = buf.long
        val hmac = ByteArray(HMAC_SIZE).also { buf.get(it) }
        return DbpHeader(type, flags, clientNonce, serverNonce, unixTime, hmac)
    }

    fun encodeHeader(header: DbpHeader, hmac: ByteArray): ByteArray {
        if (header.flags != 0) throw DbpProtocolException("flags must be zero")
        if (hmac.size != HMAC_SIZE) throw DbpProtocolException("bad hmac size")
        val buf = ByteBuffer.allocate(HEADER_SIZE).order(ByteOrder.BIG_ENDIAN)
        buf.put(MAGIC)
        buf.put(header.type.code.toByte())
        buf.put(0)
        buf.putShort(HEADER_SIZE.toShort())
        buf.putLong(header.clientNonce)
        buf.putLong(header.serverNonce)
        buf.putLong(header.unixTime)
        buf.put(hmac)
        return buf.array()
    }

    /** Bytes to read after the header before the payload length is known. */
    fun payloadPrefixLength(type: DbpMessageType): Int = when (type) {
        DbpMessageType.HELLO, DbpMessageType.HELLO_OK, DbpMessageType.OPEN_OK, DbpMessageType.HEALTH -> 0
        DbpMessageType.OPEN_ERROR -> 1
        DbpMessageType.OPEN_TCP -> 4
        DbpMessageType.DNS_QUERY, DbpMessageType.DNS_RESPONSE -> 2
        DbpMessageType.HEALTH_RESPONSE -> HEALTH_PREFIX
    }

    /** Bytes still to read after [prefix]; validated so the reader never trusts a peer-supplied length blindly. */
    fun payloadRemaining(type: DbpMessageType, prefix: ByteArray): Int {
        if (prefix.size != payloadPrefixLength(type)) throw DbpProtocolException("bad prefix")
        return when (type) {
            DbpMessageType.OPEN_TCP -> {
                val addressType = prefix[0].toInt() and 0xFF
                val length = prefix[3].toInt() and 0xFF
                when (addressType) {
                    1 -> if (length == 4) 4 else throw DbpProtocolException("ipv4 length")
                    3 -> if (length in 1..MAX_DOMAIN_LENGTH) length else throw DbpProtocolException("domain length")
                    else -> throw DbpProtocolException("address type")
                }
            }
            DbpMessageType.DNS_QUERY, DbpMessageType.DNS_RESPONSE -> {
                val length = ((prefix[0].toInt() and 0xFF) shl 8) or (prefix[1].toInt() and 0xFF)
                if (length !in DNS_MIN..MAX_CONTROL_PAYLOAD) throw DbpProtocolException("dns length")
                length
            }
            DbpMessageType.HEALTH_RESPONSE -> {
                val length = prefix[21].toInt() and 0xFF
                if (length > MAX_CARRIER) throw DbpProtocolException("carrier length")
                length
            }
            else -> 0
        }
    }

    fun decode(packet: ByteArray): DbpMessage {
        val header = decodeHeader(packet)
        return DbpMessage(header, decodePayload(header.type, packet.copyOfRange(HEADER_SIZE, packet.size)))
    }

    fun decodePayload(type: DbpMessageType, payload: ByteArray): DbpPayload {
        val prefixLength = payloadPrefixLength(type)
        if (payload.size < prefixLength) throw DbpProtocolException("truncated payload")
        val remaining = payloadRemaining(type, payload.copyOf(prefixLength))
        if (payload.size != prefixLength + remaining) throw DbpProtocolException("payload length mismatch")
        return when (type) {
            DbpMessageType.HELLO, DbpMessageType.HELLO_OK, DbpMessageType.OPEN_OK, DbpMessageType.HEALTH -> DbpPayload.Empty
            DbpMessageType.OPEN_ERROR -> DbpPayload.Error(DbpErrorCode.fromCode(payload[0].toInt() and 0xFF))
            DbpMessageType.OPEN_TCP -> decodeOpenTcp(payload)
            DbpMessageType.DNS_QUERY, DbpMessageType.DNS_RESPONSE -> DbpPayload.Dns(payload.copyOfRange(2, payload.size))
            DbpMessageType.HEALTH_RESPONSE -> decodeHealth(payload)
        }
    }

    fun decodeOpenTcp(payload: ByteArray): OpenDestination {
        if (payload.size < 4) throw DbpProtocolException("truncated open")
        val remaining = payloadRemaining(DbpMessageType.OPEN_TCP, payload.copyOf(4))
        if (payload.size != 4 + remaining) throw DbpProtocolException("open length mismatch")
        val port = ((payload[1].toInt() and 0xFF) shl 8) or (payload[2].toInt() and 0xFF)
        if (port == 0) throw DbpProtocolException("zero port")
        val body = payload.copyOfRange(4, payload.size)
        return when (payload[0].toInt()) {
            1 -> OpenDestination.Ipv4(body, port)
            else -> OpenDestination.Domain(String(body, StandardCharsets.US_ASCII), port)
        }
    }

    fun encodeOpenTcp(destination: OpenDestination): ByteArray {
        if (destination.port !in 1..65535) throw DbpProtocolException("port")
        val (type, body) = when (destination) {
            is OpenDestination.Ipv4 -> 1 to destination.address
            is OpenDestination.Domain -> 3 to destination.host.toByteArray(StandardCharsets.US_ASCII)
                .also { if (it.size !in 1..MAX_DOMAIN_LENGTH) throw DbpProtocolException("domain length") }
        }
        return ByteBuffer.allocate(4 + body.size).order(ByteOrder.BIG_ENDIAN)
            .put(type.toByte()).putShort(destination.port.toShort()).put(body.size.toByte()).put(body).array()
    }

    fun encodeError(code: DbpErrorCode): ByteArray = byteArrayOf(code.code.toByte())

    fun encodeDns(packet: ByteArray): ByteArray {
        if (packet.size !in DNS_MIN..MAX_CONTROL_PAYLOAD) throw DbpProtocolException("dns length")
        return ByteBuffer.allocate(2 + packet.size).order(ByteOrder.BIG_ENDIAN).putShort(packet.size.toShort()).put(packet).array()
    }

    fun encodeHealth(health: DbpPayload.Health): ByteArray {
        val name = health.carrierName.toByteArray(StandardCharsets.UTF_8)
        if (health.maximumSessions !in 0..MAX_SESSIONS) throw DbpProtocolException("maximum sessions")
        if (health.activeSessions !in 0..health.maximumSessions) throw DbpProtocolException("active sessions")
        if (name.size > MAX_CARRIER) throw DbpProtocolException("carrier length")
        if (health.uploadedBytes < 0 || health.downloadedBytes < 0) throw DbpProtocolException("negative counter")
        return ByteBuffer.allocate(HEALTH_PREFIX + name.size).order(ByteOrder.BIG_ENDIAN)
            .put(health.status.code.toByte())
            .putShort(health.activeSessions.toShort())
            .putShort(health.maximumSessions.toShort())
            .putLong(health.uploadedBytes)
            .putLong(health.downloadedBytes)
            .put(name.size.toByte())
            .put(name)
            .array()
    }

    private fun decodeHealth(payload: ByteArray): DbpPayload.Health {
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val status = HealthStatus.fromCode(buf.get().toInt() and 0xFF)
        val active = buf.short.toInt() and 0xFFFF
        val maximum = buf.short.toInt() and 0xFFFF
        val uploaded = buf.long
        val downloaded = buf.long
        val nameLength = buf.get().toInt() and 0xFF
        if (maximum > MAX_SESSIONS || active > maximum) throw DbpProtocolException("session counts")
        if (uploaded < 0 || downloaded < 0) throw DbpProtocolException("counter overflow")
        val nameBytes = ByteArray(nameLength).also { buf.get(it) }
        val name = try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(nameBytes)).toString()
        } catch (e: CharacterCodingException) {
            throw DbpProtocolException("carrier name utf-8")
        }
        return DbpPayload.Health(status, active, maximum, uploaded, downloaded, name)
    }
}
