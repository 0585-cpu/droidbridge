package io.droidbridge.protocol

import org.junit.Assert.*
import org.junit.Test

class UdpAssociationProtocolTest {
    // Removing 0x44 dispatch or changing its fixed payload size breaks authenticated framing.
    @Test fun `association command consumes exactly four payload bytes`() {
        val type=DbpMessageType.fromCode(0x44)
        assertEquals(4,DbpCodec.payloadPrefixLength(type))
        assertEquals(0,DbpCodec.payloadRemaining(type,byteArrayOf(4,0,0,120)))
        assertNotNull(DbpCodec.decodePayload(type,byteArrayOf(4,0,0,120)))
        assertNotNull(DbpCodec.decodePayload(type,byteArrayOf(6,0,1,44)))
    }
    @Test fun `association command rejects malformed family reserved idle and length`() {
        val type=DbpMessageType.fromCode(0x44)
        for(bytes in listOf(byteArrayOf(5,0,0,120),byteArrayOf(4,1,0,120),byteArrayOf(4,0,0,29),byteArrayOf(6,0,1,45),byteArrayOf(4,0,0),byteArrayOf(4,0,0,120,0))) {
            try { DbpCodec.decodePayload(type,bytes); fail("invalid association accepted") } catch(_: DbpProtocolException) {}
        }
    }
}
