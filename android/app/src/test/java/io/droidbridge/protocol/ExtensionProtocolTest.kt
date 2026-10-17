package io.droidbridge.protocol

import io.droidbridge.policy.DestinationPolicy
import org.junit.Assert.*
import org.junit.Test
import java.net.InetAddress

class ExtensionProtocolTest {
    @Test fun `capability request and UDP ICMP IDs are recognized`() {
        for (code in listOf(0x32,0x33,0x40,0x41,0x42,0x43,0x60,0x61,0x62)) assertEquals(code, DbpMessageType.fromCode(code).code)
    }
    @Test fun `IPv6 open preserves address bytes`() {
        val payload = byteArrayOf(2,1,-69,16) + InetAddress.getByName("2606:4700:4700::1111").address
        assertArrayEquals(payload, DbpCodec.encodeOpenTcp(DbpCodec.decodeOpenTcp(payload)))
    }
    @Test fun `public IPv6 is allowed while special networks fail closed`() {
        assertTrue(DestinationPolicy.evaluate(InetAddress.getByName("2606:4700::1111")).allowed)
        for (address in listOf("::", "::1", "fc00::1", "fe80::1", "ff02::1", "2001:db8::1", "100::1", "2001:20::1", "64:ff9b::a00:1")) assertFalse(address, DestinationPolicy.evaluate(InetAddress.getByName(address)).allowed)
        assertTrue(DestinationPolicy.evaluate(InetAddress.getByName("64:ff9b::808:808")).allowed)
    }
}
