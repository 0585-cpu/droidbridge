package io.droidbridge.pairing

/** The single registered Mac. `secret` is the 256-bit Pairing Secret; never log or stringify it. */
class PairedPeer(val peerId: String, val displayName: String, val secret: ByteArray) {
    init {
        require(secret.size == 32) { "pairing secret must be 32 bytes" }
        require(peerId.isNotEmpty())
    }

    override fun toString(): String = "PairedPeer(peerId=$peerId, displayName=$displayName)"
}
