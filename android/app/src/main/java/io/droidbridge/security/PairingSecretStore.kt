package io.droidbridge.security

import io.droidbridge.pairing.PairedPeer

/** Exactly one registered Mac. Implementations never expose the secret as a String. */
interface PairingSecretStore {
    fun load(): PairedPeer?

    /** Atomically replaces any previous peer. */
    fun replace(peer: PairedPeer)

    fun clear()
}

class InMemoryPairingSecretStore : PairingSecretStore {
    private var peer: PairedPeer? = null

    @Synchronized override fun load(): PairedPeer? = peer?.let { PairedPeer(it.peerId, it.displayName, it.secret.copyOf()) }
    @Synchronized override fun replace(peer: PairedPeer) { this.peer = PairedPeer(peer.peerId, peer.displayName, peer.secret.copyOf()) }
    @Synchronized override fun clear() { peer?.secret?.fill(0); peer = null }
}
