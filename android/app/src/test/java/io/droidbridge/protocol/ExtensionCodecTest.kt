package io.droidbridge.protocol

import org.junit.Assert.*
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.EOFException

class ExtensionCodecTest {
    @Test fun `capabilities have exact 59 byte versioned body and reject oversized length`() {
        val c = RelayCapabilities(flags=0x20f, generation=42, ipv4Ttl=65, ipv6HopLimit=64, uploadRate=10000, activeUdp=2, udpDrops=7)
        val encoded = ExtensionCodec.encodeCapabilities(c)
        assertEquals(61, encoded.size)
        assertEquals(59, encoded[1].toInt())
        assertEquals(c, ExtensionCodec.decodeCapabilities(encoded))
        assertThrows(DbpProtocolException::class.java) { DbpCodec.payloadRemaining(DbpMessageType.CAPABILITIES_RESPONSE, byteArrayOf(1,1)) }
        encoded[2] = 2
        assertThrows(DbpProtocolException::class.java) { ExtensionCodec.decodeCapabilities(encoded) }
    }
    @Test fun `UDP open carries literal address and bounded idle`() {
        val open = UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443),120)
        val encoded = ExtensionCodec.encodeUdpOpen(open)
        val decoded = ExtensionCodec.decodeUdpOpen(encoded)
        assertEquals(open.destination,decoded.destination)
        assertEquals(120, decoded.idleSeconds)
        assertThrows(DbpProtocolException::class.java) { ExtensionCodec.decodeUdpOpen(encoded.copyOf(encoded.size-1)) }
        assertThrows(IllegalArgumentException::class.java) { UdpOpen(open.destination,301) }
    }
    @Test fun `raw datagrams preserve empty maximum and wrapping sequence`() {
        for (length in listOf(0,1,1232)) {
            val packet = RawDatagram(ByteArray(length) { it.toByte() },0,0xffffffffL)
            val decoded = DatagramCodec.read(ByteArrayInputStream(DatagramCodec.encode(packet)),0)!!
            assertArrayEquals(packet.payload,decoded.payload)
            assertEquals(packet.sequence,decoded.sequence)
        }
        assertNull(DatagramCodec.read(ByteArrayInputStream(byteArrayOf()),0))
        assertThrows(EOFException::class.java) { DatagramCodec.read(ByteArrayInputStream(byteArrayOf(0)),0) }
        assertThrows(DbpProtocolException::class.java) { DatagramCodec.read(ByteArrayInputStream(byteArrayOf(4,-47,0,0,0,0,0,0)),0) }
        assertThrows(DbpProtocolException::class.java) { DatagramCodec.read(ByteArrayInputStream(byteArrayOf(0,0,2,0,0,0,0,0)),0) }
        assertThrows(DbpProtocolException::class.java) { DatagramCodec.read(ByteArrayInputStream(byteArrayOf(0,0,0,1,0,0,0,0)),0) }
    }
}
