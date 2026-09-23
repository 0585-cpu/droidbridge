package io.droidbridge.protocol

/** Malformed frame from the peer. The connection is closed without detail. */
class DbpProtocolException(message: String) : Exception(message)

enum class DbpMessageType(val code: Int) {
    HELLO(0x01), HELLO_OK(0x02),
    OPEN_TCP(0x10), OPEN_OK(0x11), OPEN_ERROR(0x12),
    DNS_QUERY(0x20), DNS_RESPONSE(0x21),
    HEALTH(0x30), HEALTH_RESPONSE(0x31),
    CAPABILITIES(0x32), CAPABILITIES_RESPONSE(0x33),
    OPEN_UDP(0x40), OPEN_UDP_OK(0x41), OPEN_UDP_ERROR(0x42), UDP_CLOSE(0x43),
    ICMP_ECHO(0x60), ICMP_ECHO_RESPONSE(0x61), ICMP_ECHO_ERROR(0x62);

    companion object {
        private val byCode = entries.associateBy { it.code }
        fun fromCode(code: Int): DbpMessageType = byCode[code] ?: throw DbpProtocolException("unknown message type")
    }
}

enum class DbpErrorCode(val code: Int) {
    AUTH_FAILED(1), VERSION_UNSUPPORTED(2), POLICY_DENIED(3), CELLULAR_UNAVAILABLE(4),
    DNS_FAILED(5), CONNECT_TIMEOUT(6), CONNECT_REFUSED(7), SESSION_LIMIT(8), INTERNAL_ERROR(9),
    UDP_UNSUPPORTED(10), DATAGRAM_TOO_LARGE(11), UDP_IDLE_TIMEOUT(12), UDP_QUEUE_OVERFLOW(13), ADDRESS_FAMILY_UNAVAILABLE(14);

    companion object {
        private val byCode = entries.associateBy { it.code }
        fun fromCode(code: Int): DbpErrorCode = byCode[code] ?: throw DbpProtocolException("unknown error code")
    }
}

enum class HealthStatus(val code: Int) {
    NOT_READY(0), READY(1), CELLULAR_UNAVAILABLE(2);

    companion object {
        private val byCode = entries.associateBy { it.code }
        fun fromCode(code: Int): HealthStatus = byCode[code] ?: throw DbpProtocolException("unknown health status")
    }
}

data class DbpHeader(
    val type: DbpMessageType,
    val flags: Int,
    val clientNonce: Long,
    val serverNonce: Long,
    val unixTime: Long,
    val hmac: ByteArray,
) {
    override fun equals(other: Any?): Boolean = other is DbpHeader && type == other.type && flags == other.flags &&
        clientNonce == other.clientNonce && serverNonce == other.serverNonce && unixTime == other.unixTime && hmac.contentEquals(other.hmac)

    override fun hashCode(): Int = (((type.hashCode() * 31 + flags) * 31 + clientNonce.hashCode()) * 31 + serverNonce.hashCode()) * 31 + unixTime.hashCode()
}

sealed interface DbpPayload {
    data object Empty : DbpPayload
    class Extension(val bytes: ByteArray) : DbpPayload

    data class Error(val code: DbpErrorCode) : DbpPayload

    class Dns(val packet: ByteArray) : DbpPayload {
        override fun equals(other: Any?): Boolean = other is Dns && packet.contentEquals(other.packet)
        override fun hashCode(): Int = packet.contentHashCode()
    }

    data class Health(
        val status: HealthStatus,
        val activeSessions: Int,
        val maximumSessions: Int,
        val uploadedBytes: Long,
        val downloadedBytes: Long,
        val carrierName: String,
    ) : DbpPayload
}

sealed interface OpenDestination : DbpPayload {
    val port: Int

    class Ipv4(val address: ByteArray, override val port: Int) : OpenDestination {
        init { require(address.size == 4) }
        override fun equals(other: Any?): Boolean = other is Ipv4 && port == other.port && address.contentEquals(other.address)
        override fun hashCode(): Int = address.contentHashCode() * 31 + port
        override fun toString(): String = "Ipv4(port=$port)" // never print the address in logs
    }

    class Ipv6(val address: ByteArray, override val port: Int) : OpenDestination {
        init { require(address.size == 16) }
        override fun equals(other: Any?): Boolean = other is Ipv6 && port == other.port && address.contentEquals(other.address)
        override fun hashCode(): Int = address.contentHashCode() * 31 + port
        override fun toString(): String = "Ipv6(port=$port)"
    }

    data class Domain(val host: String, override val port: Int) : OpenDestination {
        override fun toString(): String = "Domain(port=$port)"
    }
}

data class DbpMessage(val header: DbpHeader, val payload: DbpPayload)
