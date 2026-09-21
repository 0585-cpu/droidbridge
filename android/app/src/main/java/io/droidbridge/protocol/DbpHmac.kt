package io.droidbridge.protocol

import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

object DbpHmac {
    /** HMAC-SHA256 over the header with a zeroed hmac field followed by the payload. */
    fun compute(secret: ByteArray, header: DbpHeader, payload: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(secret, "HmacSHA256"))
        mac.update(DbpCodec.encodeHeader(header, ByteArray(DbpCodec.HMAC_SIZE)))
        mac.update(payload)
        return mac.doFinal()
    }
}
