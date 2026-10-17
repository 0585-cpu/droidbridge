package io.droidbridge.network

import io.droidbridge.protocol.IcmpRequest
import org.junit.Assert.*
import org.junit.Test

class IcmpEchoTest {
    @Test fun `ICMP builder preserves zero and maximum payload with IPv4 checksum`() {
        for(size in listOf(0,1200)) {
            val request=IcmpRequest(4,65,123,byteArrayOf(8,8,8,8),ByteArray(size) {it.toByte()})
            val bytes=IcmpPackets.request(request)
            assertEquals(8+size,bytes.size)
            assertEquals(0,IcmpPackets.checksum(bytes))
            assertArrayEquals(request.payload,bytes.copyOfRange(8,bytes.size))
        }
    }
    @Test fun `ICMP reply checks type code sequence and exact echoed payload`() {
        val request=IcmpRequest(6,0,65538,ByteArray(16),byteArrayOf(1,2,3))
        val reply=IcmpPackets.request(request).apply { this[0]=129.toByte() }
        assertTrue(IcmpPackets.matches(reply,request))
        reply[7]=5; assertFalse(IcmpPackets.matches(reply,request)); reply[7]=2
        reply[8]=9; assertFalse(IcmpPackets.matches(reply,request))
        assertFalse(IcmpPackets.matches(ByteArray(0),request))
    }
}
