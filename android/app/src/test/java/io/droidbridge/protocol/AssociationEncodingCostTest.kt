package io.droidbridge.protocol

import java.lang.management.ManagementFactory
import org.junit.Assume.assumeTrue
import org.junit.Test
import kotlin.test.*

class AssociationEncodingCostTest {
    @Volatile private var retained: ByteArray? = null

    @Test fun receiveBufferPrefixBecomesOwnedWirePacketWithZeroAddressPadding() {
        val receiveBuffer = byteArrayOf(97, 98, 99, 42, 42)
        val address = byteArrayOf(-64, 0, 2, 1)
        val wire = AssociationDatagramCodec.encode(receiveBuffer, 3, 0, 0x12345678, 4, address, 2222)
        receiveBuffer.fill(0); address.fill(0)
        val expected = "000300041234567808ae0000c0000201000000000000000000000000616263"
            .chunked(2).map { it.toInt(16).toByte() }.toByteArray()
        assertContentEquals(expected, wire, "Queued frame must survive reuse of receive/address buffers")
    }

    @Test fun prefixLengthCannotExceedAvailableBytesOrDatagramLimit() {
        val buffer = ByteArray(DatagramCodec.MAX_PAYLOAD + 1)
        for (length in listOf(-1, DatagramCodec.MAX_PAYLOAD + 1, Int.MAX_VALUE)) {
            assertFailsWith<DbpProtocolException> {
                AssociationDatagramCodec.encode(buffer, length, 1, 0, 4, byteArrayOf(1, 1, 1, 1), 53)
            }
        }
        assertFailsWith<DbpProtocolException> {
            AssociationDatagramCodec.encode(ByteArray(1), 2, 1, 0, 4, byteArrayOf(1, 1, 1, 1), 53)
        }
        for (size in listOf(0, DatagramCodec.MAX_PAYLOAD)) {
            val frame = AssociationDatagramCodec.encode(buffer, size, 1, 0xffffffffL, 6, ByteArray(16) { 1 }, 443)
            val decoded = AssociationDatagramCodec.read(frame.inputStream(), 1, 6)!!
            assertEquals(size, decoded.payload.size)
            assertEquals(0xffffffffL, decoded.sequence)
        }
    }

    @Test fun encodingReceiveBufferAvoidsIntermediatePayloadAllocation() {
        val bean = ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        assumeTrue(bean?.isThreadAllocatedMemorySupported == true)
        bean!!
        bean.isThreadAllocatedMemoryEnabled = true
        val buffer = ByteArray(1233) { it.toByte() }
        val address = byteArrayOf(1, 1, 1, 1)
        val direct = { AssociationDatagramCodec.encode(buffer, 1232, 1, 1, 4, address, 443) }
        val copied = { AssociationDatagramCodec.encode(RawAssociationDatagram(buffer.copyOf(1232), 1, 1, 4, address, 443)) }
        repeat(5000) { retained = direct(); retained = copied() }
        fun allocated(block: () -> ByteArray): Long {
            val id = Thread.currentThread().id
            val before = bean.getThreadAllocatedBytes(id)
            repeat(10000) { retained = block() }
            return bean.getThreadAllocatedBytes(id) - before
        }
        val copiedBytes = allocated(copied)
        val directBytes = allocated(direct)
        println("UDP association encoding allocation: packets=10000 copiedPathBytes=$copiedBytes directPathBytes=$directBytes")
        assertTrue(directBytes < copiedBytes * 0.75,
            "Direct encoding still allocates an intermediate payload: direct=$directBytes copied=$copiedBytes")
    }
}
