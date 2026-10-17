package io.droidbridge.security

import io.droidbridge.pairing.PairedPeer
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.map

/** Exactly one registered Mac. Implementations never expose the secret as a String. */
interface PairingSecretStore {
    fun load(): PairedPeer?

    /** Emits on subscription and persisted changes, including writes through another instance.
     * Events contain no credentials; observers load the current record and may coalesce changes. */
    val changes: Flow<Unit>

    /** Atomically replaces any previous peer. */
    fun replace(peer: PairedPeer)

    fun clear()
}

class InMemoryPairingSecretStore : PairingSecretStore {
    private var peer: PairedPeer? = null
    private val revision = MutableStateFlow(0L)
    override val changes: Flow<Unit> = revision.map { }

    @Synchronized override fun load(): PairedPeer? = peer?.let { PairedPeer(it.peerId, it.displayName, it.secret.copyOf()) }
    @Synchronized override fun replace(peer: PairedPeer) {
        this.peer = PairedPeer(peer.peerId, peer.displayName, peer.secret.copyOf())
        revision.value++
    }
    @Synchronized override fun clear() { peer?.secret?.fill(0); peer = null; revision.value++ }
}
