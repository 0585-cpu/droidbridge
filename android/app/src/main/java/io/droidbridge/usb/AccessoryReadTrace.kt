package io.droidbridge.usb

import java.io.InputStream
import java.io.IOException
import java.security.MessageDigest

/** One reader records IO; watchdogs may snapshot it. The monitor never covers blocking source IO. */
internal class AccessoryReadTrace(private val source: InputStream, private val fingerprints: Boolean = false) : InputStream() {
    /** returned=-1 is EOF; -2 records an IOException without suppressing/retrying it. */
    data class Read(val ordinal: Long, val requested: Int, val returned: Int, val endOffset: Long,
                    val sha256: String? = null, val prefix16Sha256: String? = null)
    data class Snapshot(val calls: Long, val bytesReceived: Long, val recent: List<Read>)

    private var calls = 0L
    private var bytesReceived = 0L
    // Avoid per-transfer allocation while measuring a possible scheduling/IO failure.
    private val requested = IntArray(8)
    private val returned = IntArray(8)
    private val endOffsets = LongArray(8)
    private val digest = if (fingerprints) MessageDigest.getInstance("SHA-256") else null
    private val hashes = ByteArray(8 * 32)
    private val prefixHashes = ByteArray(8 * 32)
    private val singleByte = ByteArray(1)
    private var next = 0

    @Synchronized fun snapshot(): Snapshot {
        val count = minOf(calls, 8).toInt()
        val first = if (calls < 8) 0 else next
        return Snapshot(calls, bytesReceived, List(count) { offset ->
            val slot = (first + offset) % 8
            Read(calls - count + 1 + offset, requested[slot], returned[slot], endOffsets[slot],
                if (fingerprints && returned[slot] >= 0) hex(hashes, slot * 32) else null,
                if (fingerprints && returned[slot] >= 0) hex(prefixHashes, slot * 32) else null)
        })
    }
    private fun hex(bytes: ByteArray, offset: Int): String = buildString(64) {
        val digits = "0123456789abcdef"
        for (index in offset until offset + 32) {
            val value = bytes[index].toInt() and 255
            append(digits[value ushr 4])
            append(digits[value and 15])
        }
    }
    @Synchronized private fun record(requestSize: Int, result: Int, bytes: ByteArray? = null, offset: Int = 0) {
        calls++
        if (result > 0) bytesReceived += result
        if (digest != null && result >= 0 && bytes != null) {
            digest.update(bytes, offset, result)
            digest.digest(hashes, next * 32, 32)
            digest.update(bytes, offset, minOf(16, result))
            digest.digest(prefixHashes, next * 32, 32)
        }
        requested[next] = requestSize
        returned[next] = result
        endOffsets[next] = bytesReceived
        next = (next + 1) % 8
    }
    override fun read(): Int = try {
        source.read().also {
            singleByte[0] = it.toByte()
            record(1, if (it < 0) -1 else 1, singleByte)
        }
    } catch (error: IOException) {
        record(1, -2)
        throw error
    }
    override fun read(bytes: ByteArray, offset: Int, length: Int): Int = try {
        source.read(bytes, offset, length).also { record(length, it, bytes, offset) }
    } catch (error: IOException) {
        record(length, -2)
        throw error
    }
    override fun available(): Int = source.available()
    override fun close() = source.close()
}
