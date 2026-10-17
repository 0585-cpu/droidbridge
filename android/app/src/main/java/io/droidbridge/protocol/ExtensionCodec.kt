package io.droidbridge.protocol

import java.io.DataInputStream
import java.io.InputStream
import java.nio.ByteBuffer

object Capability {
    const val TCP4 = 1L
    const val UDP4 = 1L shl 1
    const val TCP6 = 1L shl 2
    const val UDP6 = 1L shl 3
    const val ICMP4 = 1L shl 4
    const val ICMP6 = 1L shl 5
    const val NAT64 = 1L shl 6
    const val PROFILES = 1L shl 9
    const val UDP_ASSOCIATION = 1L shl 10
}

data class RelayCapabilities(
    val flags: Long = Capability.TCP4,
    val generation: Long = 0,
    val ipv4Ttl: Int = 0,
    val ipv6HopLimit: Int = 0,
    val policyFlags: Int = 0,
    val uploadRate: Long = 0,
    val downloadRate: Long = 0,
    val burstBytes: Long = 0,
    val activeUdp: Int = 0,
    val udpDrops: Long = 0,
    val nat64Prefix: List<Byte> = emptyList(),
) : DbpPayload

data class UdpOpen(val destination: OpenDestination, val idleSeconds: Int = 120) : DbpPayload {
    init { require(destination !is OpenDestination.Domain); require(idleSeconds in 30..300) }
}

data class UdpAssociationOpen(val family: Int, val idleSeconds: Int = 120) : DbpPayload {
    init { require(family == 4 || family == 6); require(idleSeconds in 30..300) }
}

data class IcmpRequest(val family: Int, val ttl: Int, val requestId: Long, val destination: ByteArray, val payload: ByteArray) : DbpPayload

data class IcmpReply(val requestId: Long, val family: Int, val source: ByteArray, val payload: ByteArray, val rttMicros: Long, val receivedHop: Int = 0)

object ExtensionCodec {
    fun encodeCapabilities(c: RelayCapabilities): ByteArray {
        require(c.nat64Prefix.isEmpty() || c.nat64Prefix.size == 16)
        return ByteBuffer.allocate(61).putShort(59).put(1).putLong(c.flags).putLong(c.generation)
            .put(c.ipv4Ttl.toByte()).put(c.ipv6HopLimit.toByte()).put(c.policyFlags.toByte())
            .putInt(c.uploadRate.toInt()).putInt(c.downloadRate.toInt()).putInt(c.burstBytes.toInt())
            .putShort(c.activeUdp.toShort()).putLong(c.udpDrops).put(if (c.nat64Prefix.isEmpty()) 0 else 96.toByte())
            .put(if (c.nat64Prefix.isEmpty()) ByteArray(16) else c.nat64Prefix.toByteArray()).array()
    }
    fun decodeCapabilities(bytes: ByteArray): RelayCapabilities {
        if (bytes.size != 61 || bytes[0] != 0.toByte() || bytes[1] != 59.toByte() || bytes[2] != 1.toByte()) throw DbpProtocolException("capabilities version or size")
        val b = ByteBuffer.wrap(bytes).apply { position(3) }
        val c = RelayCapabilities(b.long,b.long,b.get().toInt() and 255,b.get().toInt() and 255,b.get().toInt() and 255,
            b.int.toLong() and 0xffffffffL,b.int.toLong() and 0xffffffffL,b.int.toLong() and 0xffffffffL,b.short.toInt() and 65535,b.long)
        val bits = b.get().toInt() and 255
        val prefix = ByteArray(16).also { b.get(it) }
        if (bits != 0 && bits != 96) throw DbpProtocolException("NAT64 prefix")
        if (bits == 0 && prefix.any { it != 0.toByte() }) throw DbpProtocolException("absent NAT64 prefix")
        return c.copy(nat64Prefix=if (bits == 0) emptyList() else prefix.toList())
    }
    fun encodeUdpOpen(open: UdpOpen): ByteArray = DbpCodec.encodeOpenTcp(open.destination) + byteArrayOf((open.idleSeconds shr 8).toByte(),open.idleSeconds.toByte())
    fun decodeUdpOpen(bytes: ByteArray): UdpOpen {
        if (bytes.size < 6) throw DbpProtocolException("UDP open size")
        if (bytes[0].toInt() !in 1..2) throw DbpProtocolException("UDP literal address required")
        val idle = ((bytes[bytes.size-2].toInt() and 255) shl 8) or (bytes.last().toInt() and 255)
        if (idle !in 30..300) throw DbpProtocolException("UDP idle")
        return UdpOpen(DbpCodec.decodeOpenTcp(bytes.copyOf(bytes.size-2)),idle)
    }
    fun encodeUdpAssociationOpen(open: UdpAssociationOpen): ByteArray =
        ByteBuffer.allocate(4).put(open.family.toByte()).put(0).putShort(open.idleSeconds.toShort()).array()
    fun decodeUdpAssociationOpen(bytes: ByteArray): UdpAssociationOpen {
        if(bytes.size != 4) throw DbpProtocolException("UDP association size")
        val family=bytes[0].toInt() and 255
        val idle=((bytes[2].toInt() and 255) shl 8) or (bytes[3].toInt() and 255)
        if(family !in listOf(4,6) || bytes[1] != 0.toByte() || idle !in 30..300) throw DbpProtocolException("UDP association open")
        return UdpAssociationOpen(family,idle)
    }
    fun encodeUdpOk(id: Int, idle: Int): ByteArray = ByteBuffer.allocate(8).putInt(id).putShort(idle.toShort()).putShort(1232).array()
    fun encodeUdpError(error: DbpErrorCode): ByteArray = ByteBuffer.allocate(4).putShort(error.code.toShort()).putShort(0).array()
    fun decodeIcmpRequest(bytes: ByteArray): IcmpRequest {
        if (bytes.size < 24) throw DbpProtocolException("ICMP size")
        val b=ByteBuffer.wrap(bytes); val family=b.get().toInt() and 255; val ttl=b.get().toInt() and 255; val size=b.short.toInt() and 65535
        val id=b.int.toLong() and 0xffffffffL; val slot=ByteArray(16).also { b.get(it) }
        if (family !in listOf(4,6) || size > 1200 || bytes.size != 24+size) throw DbpProtocolException("ICMP request")
        if (family == 4 && slot.drop(4).any { it != 0.toByte() }) throw DbpProtocolException("IPv4 padding")
        return IcmpRequest(family,ttl,id,slot.copyOf(if (family==4) 4 else 16),bytes.copyOfRange(24,bytes.size))
    }
    fun encodeIcmpReply(reply: IcmpReply): ByteArray = ByteBuffer.allocate(32+reply.payload.size).putInt(reply.requestId.toInt())
        .put(reply.family.toByte()).put(reply.receivedHop.toByte()).putShort(reply.payload.size.toShort()).putLong(reply.rttMicros)
        .put(reply.source.copyOf(16)).put(reply.payload).array()
    fun encodeIcmpError(id: Long,error: DbpErrorCode): ByteArray = ByteBuffer.allocate(6).putInt(id.toInt()).putShort(error.code.toShort()).array()
}

data class RawDatagram(val payload: ByteArray,val flags: Int,val sequence: Long)
object DatagramCodec {
    const val MAX_PAYLOAD=1232
    fun encode(packet: RawDatagram): ByteArray {
        if (packet.payload.size > MAX_PAYLOAD || packet.flags !in 0..1) throw DbpProtocolException("datagram")
        return ByteBuffer.allocate(8+packet.payload.size).putShort(packet.payload.size.toShort()).put(packet.flags.toByte()).put(0).putInt(packet.sequence.toInt()).put(packet.payload).array()
    }
    fun read(input: InputStream, direction: Int): RawDatagram? {
        val first=input.read(); if(first < 0) return null
        val stream=DataInputStream(input)
        val header=ByteArray(8)
        header[0]=first.toByte()
        stream.readFully(header,1,7)
        val fields=ByteBuffer.wrap(header)
        val size=fields.short.toInt() and 65535
        val flags=fields.get().toInt() and 255
        val reserved=fields.get().toInt() and 255
        val sequence=fields.int.toLong() and 0xffffffffL
        if(size > MAX_PAYLOAD || flags != direction || reserved != 0) throw DbpProtocolException("datagram header")
        return RawDatagram(ByteArray(size).also { stream.readFully(it) },flags,sequence)
    }
}
