package io.droidbridge.protocol
import java.io.ByteArrayInputStream
import java.io.InputStream
import kotlin.test.*
class UdpReadCostTest {
    @Test fun associationHeaderUsesBulkReadsAndPreservesDatagrams() {
        val wire = AssociationDatagramCodec.encode(RawAssociationDatagram(ByteArray(1232) { 7 },0,1,4,byteArrayOf(8,8,8,8),443))
        val raw = ByteArrayInputStream(wire)
        var calls = 0
        val source = object : InputStream() {
            override fun read(): Int { calls++; return raw.read() }
            override fun read(b: ByteArray, o: Int, n: Int): Int { calls++; return raw.read(b,o,n) }
        }
        val packet = AssociationDatagramCodec.read(source,0,4)!!
        assertEquals(1232, packet.payload.size)
        assertTrue(calls <= 4, "Header fields cause $calls underlying reads")
    }
}
