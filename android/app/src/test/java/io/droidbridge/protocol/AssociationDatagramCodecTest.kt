package io.droidbridge.protocol

import org.junit.Assert.*
import org.junit.Test
import java.io.EOFException

class AssociationDatagramCodecTest {
    private fun hex(value: String)=value.chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    @Test fun `literal IPv4 and IPv6 association fixtures preserve all peer fields`() {
        val ipv4=hex("000300041234567808ae0000c0000201000000000000000000000000616263")
        val packet=RawAssociationDatagram(byteArrayOf(97,98,99),0,0x12345678,4,byteArrayOf(-64,0,2,1),2222)
        assertArrayEquals(ipv4,AssociationDatagramCodec.encode(packet))
        val decoded=AssociationDatagramCodec.read(ipv4.inputStream(),0,4)!!
        assertEquals(2222,decoded.port); assertEquals(0x12345678L,decoded.sequence)
        assertArrayEquals(packet.address,decoded.address); assertArrayEquals(packet.payload,decoded.payload)
        val ipv6=hex("00000106ffffffff01bb000020010db8000000000000000000000001")
        val empty=RawAssociationDatagram(byteArrayOf(),1,0xffffffffL,6,hex("20010db8000000000000000000000001"),443)
        assertArrayEquals(ipv6,AssociationDatagramCodec.encode(empty))
        val six=AssociationDatagramCodec.read(ipv6.inputStream(),1,6)!!
        assertEquals(0,six.payload.size); assertEquals(443,six.port); assertEquals(0xffffffffL,six.sequence)
        assertArrayEquals(empty.address,six.address)
        assertArrayEquals(hex("04000078"),ExtensionCodec.encodeUdpAssociationOpen(UdpAssociationOpen(4)))
    }
    @Test fun `truncation is rejected at every byte while clean EOF remains clean`() {
        val frame=hex("000300041234567808ae0000c0000201000000000000000000000000616263")
        assertNull(AssociationDatagramCodec.read(byteArrayOf().inputStream(),0,4))
        for(length in 1 until frame.size) {
            try { AssociationDatagramCodec.read(frame.copyOf(length).inputStream(),0,4); fail("truncation accepted at $length") } catch(_: EOFException) {}
        }
    }
    @Test fun `oversized payload is rejected before reading address or payload`() {
        val input=hex("ffff00040000000000010000").inputStream()
        try { AssociationDatagramCodec.read(input,0,4); fail("oversize accepted") } catch(_: DbpProtocolException) {}
        assertEquals(0,input.available())
    }
    @Test fun `encoder rejects invalid family address length direction port and sequence`() {
        val base=RawAssociationDatagram(byteArrayOf(),0,0,4,byteArrayOf(1,1,1,1),53)
        for(packet in listOf(base.copy(family=5),base.copy(address=ByteArray(16)),base.copy(direction=2),base.copy(port=0),base.copy(port=65536),base.copy(sequence=-1),base.copy(sequence=0x100000000L),base.copy(payload=ByteArray(DatagramCodec.MAX_PAYLOAD+1)))) {
            try { AssociationDatagramCodec.encode(packet); fail("invalid frame accepted") } catch(_: DbpProtocolException) {}
        }
    }
}
