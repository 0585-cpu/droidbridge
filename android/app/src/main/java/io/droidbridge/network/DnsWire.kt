package io.droidbridge.network

/** Minimal DNS wire helpers: transaction id, QR/TC bits. No caching, no name logging. */
object DnsWire {
    const val MIN_PACKET = 12
    const val MAX_PACKET = 4096

    fun transactionId(packet: ByteArray): Int = ((packet[0].toInt() and 0xFF) shl 8) or (packet[1].toInt() and 0xFF)
    fun isResponse(packet: ByteArray): Boolean = (packet[2].toInt() and 0x80) != 0
    fun isTruncated(packet: ByteArray): Boolean = (packet[2].toInt() and 0x02) != 0

    fun validateForwardable(packet: ByteArray) {
        if (packet.size < MIN_PACKET || packet.size > MAX_PACKET) throw DnsFailureException(DnsFailure.MALFORMED)
    }
}
