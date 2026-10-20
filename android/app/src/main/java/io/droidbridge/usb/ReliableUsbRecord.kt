package io.droidbridge.usb

import java.io.IOException
import java.nio.ByteBuffer
import java.security.MessageDigest

/** Integrity envelope, not authentication. DBP and application TLS remain inside the byte stream. */
data class ReliableUsbRecord(val kind: Int, val epoch: ByteArray, val sequence: Long = 0,
                             val ack: Long = 0, val payload: ByteArray = ByteArray(0)) {
    fun encode(): ByteArray = ByteArray(80 + payload.size).also { encodeInto(it) }

    /** The writer reuses one buffer: a fresh 16 KiB array per record was large-object GC churn. */
    fun encodeInto(target: ByteArray): Int {
        if (!valid(kind, payload.size, sequence, ack) || epoch.size != 16) throw IOException("invalid reliable USB record")
        if (target.size < 80 + payload.size) throw IOException("reliable USB encode buffer too small")
        ByteBuffer.wrap(target).put(MAGIC).putInt(kind shl 24).putInt(payload.size)
            .put(epoch).putLong(sequence).putLong(ack)
        val hash = hashes.get()!!
        hash.into(payload, 0, payload.size, target, 48)
        hash.into(target, 0, 64, target, 64)
        payload.copyInto(target, 80)
        return 80 + payload.size
    }
    companion object {
        val MAGIC = "DBR3LINK".toByteArray(Charsets.US_ASCII)
        const val MAX_PAYLOAD = 16384
        fun valid(kind: Int, length: Int, sequence: Long, ack: Long): Boolean =
            kind in 1..4 && length in 0..MAX_PAYLOAD && sequence >= 0 && ack >= 0 &&
                (if (kind == 3) sequence > 0 && length > 0 else sequence == 0L && length == 0) &&
                (kind > 2 || ack == 0L)
        // Writers and vector callers may run concurrently; digest state is never shared across
        // threads. Each digest() resets its state, and mandatory wire checks remain unchanged.
        private class Hasher {
            private val digest = MessageDigest.getInstance("SHA-256")
            private val scratch = ByteArray(32)
            fun into(source: ByteArray, offset: Int, length: Int, target: ByteArray, targetOffset: Int) {
                digest.update(source, offset, length)
                digest.digest(scratch, 0, scratch.size)
                scratch.copyInto(target, targetOffset, 0, 16)
            }
        }
        private val hashes = ThreadLocal.withInitial { Hasher() }
        fun digest(bytes: ByteArray): ByteArray = ByteArray(16).also {
            hashes.get()!!.into(bytes, 0, bytes.size, it, 0)
        }
    }
}

/** Single-reader incremental decoder. Scratch storage never escapes into delivered records. */
class ReliableUsbDecoder {
    private val pending = ByteArray(65536 + 80 + ReliableUsbRecord.MAX_PAYLOAD)
    private var start = 0
    private var end = 0
    private data class Header(val kind: Int, val length: Int, val sequence: Long, val ack: Long)
    private var validated: Header? = null
    private val digest = MessageDigest.getInstance("SHA-256")

    private fun matchesHash(offset: Int, length: Int, expected: Int): Boolean {
        digest.update(pending, offset, length)
        val hash = digest.digest()
        return (0 until 16).all { hash[it] == pending[expected + it] }
    }

    fun append(bytes: ByteArray): List<ReliableUsbRecord> = append(bytes, 0, bytes.size)

    fun append(bytes: ByteArray, offset: Int, length: Int): List<ReliableUsbRecord> {
        if (offset < 0 || length < 0 || offset > bytes.size-length || length > 65536)
            throw IOException("invalid USB read range")
        if (pending.size - end < length) {
            pending.copyInto(pending, 0, start, end)
            end -= start
            start = 0
        }
        bytes.copyInto(pending, end, offset, offset+length)
        end += length
        val result = ArrayList<ReliableUsbRecord>()
        while (end - start >= 8) {
            if (!ReliableUsbRecord.MAGIC.indices.all { pending[start+it] == ReliableUsbRecord.MAGIC[it] }) { start++; continue }
            if (end - start < 80) break
            var header = validated
            if (header == null) {
                if (!matchesHash(start, 64, start+64)) { start++; continue }
                val buffer = ByteBuffer.wrap(pending, start, 80).slice()
                val candidate = Header(buffer.get(8).toInt() and 255, buffer.getInt(12), buffer.getLong(32), buffer.getLong(40))
                if (!(9..11).all { buffer.get(it) == 0.toByte() } ||
                    !ReliableUsbRecord.valid(candidate.kind,candidate.length,candidate.sequence,candidate.ack)) { start++; continue }
                header = candidate
                validated = header
            }
            if (end - start < 80 + header.length) break
            validated = null
            if (!matchesHash(start+80, header.length, start+48)) { start++; continue }
            result += ReliableUsbRecord(header.kind, pending.copyOfRange(start+16,start+32),
                header.sequence, header.ack, pending.copyOfRange(start+80,start+80+header.length))
            start += 80 + header.length
        }
        if (start == end) { start = 0; end = 0 }
        return result
    }
}
