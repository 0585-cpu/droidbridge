package io.droidbridge.security

fun interface EpochClock {
    fun epochSeconds(): Long

    companion object {
        val SYSTEM = EpochClock { System.currentTimeMillis() / 1000 }
    }
}

/** Bounded replay cache: newest [maxEntries] nonces, each remembered for [ttlSeconds]. */
class NonceReplayCache(
    private val maxEntries: Int = 1024,
    private val ttlSeconds: Long = 300,
    private val clock: EpochClock = EpochClock.SYSTEM,
) {
    private val seen = LinkedHashMap<Long, Long>()

    @Synchronized
    fun checkAndAdd(nonce: Long): Boolean {
        expire()
        if (seen.containsKey(nonce)) return false
        seen[nonce] = clock.epochSeconds()
        val iterator = seen.entries.iterator()
        while (seen.size > maxEntries) { iterator.next(); iterator.remove() }
        return true
    }

    @Synchronized
    fun contains(nonce: Long): Boolean { expire(); return seen.containsKey(nonce) }

    private fun expire() {
        val cutoff = clock.epochSeconds() - ttlSeconds
        val iterator = seen.entries.iterator()
        while (iterator.hasNext() && iterator.next().value < cutoff) iterator.remove()
    }
}
