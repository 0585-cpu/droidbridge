package io.droidbridge.usb

import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer

/** Transport-only envelope; DBP authentication remains inside each logical stream. */
data class AoaFrame(val type: Int, val streamId: Int, val service: Int = 0, val payload: ByteArray = ByteArray(0)) {
    fun encode(): ByteArray {
        validate(type, streamId, service, payload.size)
        validateCredit()
        return ByteBuffer.allocate(16 + payload.size).putInt(MAGIC).put(2).put(type.toByte())
            .put(service.toByte()).put(0).putInt(streamId).putInt(payload.size).put(payload).array()
    }

    fun credit(): Long = ByteBuffer.wrap(payload).long

    private fun validateCredit() {
        if (type == WINDOW && credit() < 0) throw IOException("invalid AOA consumed count")
    }

    companion object {
        const val OPEN = 1
        const val OPEN_OK = 2
        const val DATA = 3
        const val FIN = 4
        const val CLOSE = 5
        const val WINDOW = 6
        const val RESET = 7
        const val RESET_OK = 8
        const val PING = 9
        const val PONG = 10
        const val RELAY = 1
        const val PAIRING = 2
        const val MAX_PAYLOAD = 16384
        // Sender budget: one 16 KiB descriptor write includes both envelope headers.
        // Keep MAX_PAYLOAD for receiving frames from existing peers.
        const val SEND_PAYLOAD = 16384 - 16 - 80
        // Frames the writer may pack into one reliable record (one 16 KiB descriptor write).
        const val WRITE_BUDGET = 16384 - 80
        const val INITIAL_CREDIT = 65536
        private const val MAGIC = 0x4442414d

        /** DATA straight from a caller's buffer: one allocation and one copy per frame. */
        fun encodeData(streamId: Int, source: ByteArray, offset: Int, length: Int): ByteArray {
            validate(DATA, streamId, 0, length)
            return ByteBuffer.allocate(16 + length).putInt(MAGIC).put(2).put(DATA.toByte()).put(0).put(0)
                .putInt(streamId).putInt(length).put(source, offset, length).array()
        }

        // Version 2 WINDOW is a cumulative count, so repeating it cannot inflate credit.
        fun window(id: Int, bytes: Long) = AoaFrame(WINDOW, id, payload = ByteBuffer.allocate(8).putLong(bytes).array())

        private fun validate(type: Int, id: Int, service: Int, length: Int) {
            if (type in RESET..PONG) {
                if (id != 0 || service != 0 || length != if (type <= RESET_OK) 16 else 0)
                    throw IOException("invalid AOA session control")
                return
            }
            if (type !in OPEN..WINDOW || id <= 0 || id and 1 == 0 || length !in 0..MAX_PAYLOAD)
                throw IOException("invalid AOA frame")
            if (if (type == OPEN) service !in RELAY..PAIRING else service != 0)
                throw IOException("invalid AOA service")
            when (type) {
                DATA -> if (length == 0) throw IOException("empty AOA DATA")
                WINDOW -> if (length != 8) throw IOException("invalid AOA window length")
                else -> if (length != 0) throw IOException("invalid AOA control payload")
            }
        }

        /** null means clean EOF between frames; a partial frame always throws. */
        fun read(input: InputStream): AoaFrame? {
            val header = ByteArray(16)
            val count = input.read(header, 0, header.size)
            if (count == -1) return null
            val source = DataInputStream(input)
            source.readFully(header, count, header.size - count)
            val buffer = ByteBuffer.wrap(header)
            if (buffer.int != MAGIC) throw IOException("invalid AOA magic")
            if (buffer.get().toInt() != 2) throw IOException("AOA version mismatch; update both DroidBridge apps")
            val type = buffer.get().toInt() and 255
            val service = buffer.get().toInt() and 255
            if (buffer.get().toInt() != 0) throw IOException("invalid AOA reserved byte")
            val id = buffer.int
            val length = buffer.int
            validate(type, id, service, length) // before allocation or body read
            val payload = ByteArray(length).also(source::readFully)
            return AoaFrame(type, id, service, payload).also { it.validateCredit() }
        }
    }
}
