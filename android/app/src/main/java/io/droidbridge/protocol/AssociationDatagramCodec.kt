package io.droidbridge.protocol

import java.io.DataInputStream
import java.io.InputStream
import java.nio.ByteBuffer

/** A peer address belongs to this packet, not the lifetime of the association. */
data class RawAssociationDatagram(val payload: ByteArray, val direction: Int, val sequence: Long,
    val family: Int, val address: ByteArray, val port: Int)

object AssociationDatagramCodec {
    const val HEADER_SIZE=28
    const val MAX_PAYLOAD=DatagramCodec.MAX_PAYLOAD

    fun encode(payload: ByteArray, length: Int, direction: Int, sequence: Long,
        family: Int, address: ByteArray, port: Int): ByteArray {
        if(length < 0 || length > payload.size || length > MAX_PAYLOAD || direction !in 0..1 ||
            (family != 4 && family != 6) || address.size != (if(family == 4) 4 else 16) ||
            port !in 1..65535 || sequence !in 0..0xffffffffL) throw DbpProtocolException("association datagram")
        // The queued frame owns one payload copy; the reusable receive buffer can change next.
        // ByteArray starts zeroed, including the IPv4 address slot's twelve padding bytes.
        val wire = ByteArray(HEADER_SIZE + length)
        val fields = ByteBuffer.wrap(wire)
        fields.putShort(length.toShort()).put(direction.toByte()).put(family.toByte()).putInt(sequence.toInt())
            .putShort(port.toShort()).putShort(0).put(address)
        fields.position(HEADER_SIZE)
        fields.put(payload, 0, length)
        return wire
    }

    fun encode(packet: RawAssociationDatagram): ByteArray = encode(packet.payload, packet.payload.size,
        packet.direction, packet.sequence, packet.family, packet.address, packet.port)

    fun read(input: InputStream,direction: Int,family: Int): RawAssociationDatagram? {
        val first=input.read(); if(first<0) return null
        val stream=DataInputStream(input)
        val header=ByteArray(12)
        header[0]=first.toByte()
        stream.readFully(header,1,header.size-1)
        val fields=ByteBuffer.wrap(header)
        val size=fields.short.toInt() and 65535
        val receivedDirection=fields.get().toInt() and 255
        val receivedFamily=fields.get().toInt() and 255
        val sequence=fields.int.toLong() and 0xffffffffL
        val port=fields.short.toInt() and 65535
        val reserved=fields.short.toInt() and 65535
        if(size>MAX_PAYLOAD || direction !in 0..1 || receivedDirection!=direction || family !in listOf(4,6) ||
            receivedFamily!=family || port==0 || reserved!=0) throw DbpProtocolException("association header")
        val slot=ByteArray(16).also(stream::readFully)
        if(family==4 && (4..15).any { slot[it]!=0.toByte() }) throw DbpProtocolException("association IPv4 padding")
        return RawAssociationDatagram(ByteArray(size).also(stream::readFully),direction,sequence,family,slot.copyOf(if(family==4) 4 else 16),port)
    }
}
