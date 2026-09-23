package io.droidbridge.usb

import java.io.ByteArrayInputStream
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import java.io.IOException

class AoaFrameTest {
    private val open = byteArrayOf(0x44,0x42,0x41,0x4d, 1,1,2,0, 0,0,0,1, 0,0,0,0)

    @Test fun `literal pairing OPEN matches Mac encoding`() {
        val frame = AoaFrame.read(ByteArrayInputStream(open))!!
        assertEquals(AoaFrame.OPEN, frame.type)
        assertEquals(1, frame.streamId)
        assertEquals(AoaFrame.PAIRING, frame.service)
        assertContentEquals(open, frame.encode())
    }

    @Test fun `length is rejected before reading oversized payload`() {
        val bytes = open.copyOf().apply { this[5] = 3; this[6] = 0; this[12] = 0x7f }
        assertFailsWith<IOException> { AoaFrame.read(ByteArrayInputStream(bytes)) }
    }

    @Test fun `malformed headers and truncated payload fail closed`() {
        for ((offset, value) in listOf(0 to 0, 4 to 2, 5 to 9, 6 to 3, 7 to 1, 11 to 2)) {
            val bytes = open.copyOf().apply { this[offset] = value.toByte() }
            assertFailsWith<IOException> { AoaFrame.read(ByteArrayInputStream(bytes)) }
        }
        val bytes = open.copyOf().apply { this[5] = 3; this[6] = 0; this[15] = 3 } + byteArrayOf(1,2)
        assertFailsWith<IOException> { AoaFrame.read(ByteArrayInputStream(bytes)) }
    }

    @Test fun `DATA and WINDOW boundaries are enforced`() {
        assertFailsWith<IOException> { AoaFrame(AoaFrame.DATA, 1).encode() }
        assertFailsWith<IOException> { AoaFrame(AoaFrame.DATA, 1, payload = ByteArray(16385)).encode() }
        assertFailsWith<IOException> { AoaFrame(AoaFrame.WINDOW, 1, payload = ByteArray(4)).encode() }
        val payload = ByteArray(16384) { 7 }
        assertContentEquals(payload, AoaFrame.read(ByteArrayInputStream(AoaFrame(AoaFrame.DATA, 1, payload = payload).encode()))!!.payload)
    }
}
