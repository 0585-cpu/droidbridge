package io.droidbridge.protocol

import io.droidbridge.util.Json
import java.io.File
import java.io.ByteArrayInputStream
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalStdlibApi::class)
class SharedExtensionVectorsTest {
    @Test fun `canonical extension control packets preserve lengths HMAC and typed payloads`() {
        val fixture=Json.parseObject(File(System.getProperty("droidbridge.protocolVectors"),"dbp-extensions.json").readText())
        val secret=(fixture["secret_hex"] as String).hexToByteArray()
        for(entry in fixture["vectors"] as List<*>) {
            val v=entry as Map<*,*>
            val packet=(v["packet_hex"] as String).hexToByteArray()
            val bytes=(v["payload_hex"] as String).hexToByteArray()
            val msg=DbpCodec.decode(packet)
            assertEquals((v["message_type"] as Long).toInt(),msg.header.type.code)
            assertArrayEquals((v["header_hex"] as String).hexToByteArray(),DbpCodec.encodeHeader(msg.header,DbpHmac.compute(secret,msg.header.copy(hmac=ByteArray(32)),bytes)))
            val encoded=when(val payload=msg.payload) {
                is RelayCapabilities -> ExtensionCodec.encodeCapabilities(payload)
                is UdpOpen -> ExtensionCodec.encodeUdpOpen(payload)
                is OpenDestination -> DbpCodec.encodeOpenTcp(payload)
                else -> bytes
            }
            assertArrayEquals(v["name"] as String,bytes,encoded)
        }
        for(entry in fixture["datagrams"] as List<*>) {
            val v=entry as Map<*,*>
            val wire=(v["wire_hex"] as String).hexToByteArray()
            val packet=DatagramCodec.read(ByteArrayInputStream(wire),if(v["inbound"] as Boolean) 1 else 0)!!
            assertArrayEquals((v["payload_hex"] as String).hexToByteArray(),packet.payload)
            assertEquals(v["sequence"] as Long,packet.sequence)
            assertArrayEquals(wire,DatagramCodec.encode(packet))
        }
    }
}
