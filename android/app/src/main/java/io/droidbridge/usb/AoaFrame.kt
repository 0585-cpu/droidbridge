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
        return ByteBuffer.allocate(16 + payload.size).putInt(MAGIC).put(1).put(type.toByte())
            .put(service.toByte()).put(0).putInt(streamId).putInt(payload.size).put(payload).array()
    }

    fun credit(): Int = ByteBuffer.wrap(payload).int

    private fun validateCredit() {
        if (type == WINDOW && credit() !in 1..INITIAL_CREDIT) throw IOException("invalid AOA credit")
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
        const val INITIAL_CREDIT = 65536
        private const val MAGIC = 0x4442414d

        fun window(id: Int, bytes: Int) = AoaFrame(WINDOW, id, payload = ByteBuffer.allocate(4).putInt(bytes).array())

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
                WINDOW -> if (length != 4) throw IOException("invalid AOA window length")
                else -> if (length != 0) throw IOException("invalid AOA control payload")
            }
        }

        /** null means clean EOF between frames; a partial frame always throws. */
        fun read(input: InputStream): AoaFrame? {
            val first = input.read()
            if (first == -1) return null
            val header = ByteArray(16)
            header[0] = first.toByte()
            val source = DataInputStream(input)
            source.readFully(header, 1, 15)
            val buffer = ByteBuffer.wrap(header)
            if (buffer.int != MAGIC || buffer.get().toInt() != 1) throw IOException("invalid AOA version")
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
