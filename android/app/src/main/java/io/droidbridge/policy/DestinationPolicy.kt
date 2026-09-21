package io.droidbridge.policy

import java.net.Inet4Address
import java.net.InetAddress

/** Codes match "results" in protocol/test-vectors/destination-policy.json; UNSUPPORTED_ADDRESS_FAMILY is Android-only. */
enum class PolicyResult(val code: Int, val fixtureName: String) {
    ALLOW(0, "ALLOW"),
    DENY_PRIVATE(1, "PRIVATE"),
    DENY_SHARED(2, "SHARED"),
    DENY_LOOPBACK(3, "LOOPBACK"),
    DENY_LINK_LOCAL(4, "LINK_LOCAL"),
    DENY_RESERVED(5, "RESERVED"),
    DENY_DOCUMENTATION(6, "DOCUMENTATION"),
    DENY_BENCHMARK(7, "BENCHMARK"),
    DENY_MULTICAST(8, "MULTICAST"),
    UNSUPPORTED_ADDRESS_FAMILY(100, "UNSUPPORTED_ADDRESS_FAMILY");

    val allowed: Boolean get() = this == ALLOW
}

class DestinationDeniedException(val result: PolicyResult) : Exception("destination denied: $result")

/** IPv4 destination policy (spec §10). Table must stay identical to core/src/destination_policy.c. */
object DestinationPolicy {
    private class Range(a: Int, b: Int, c: Int, d: Int, bits: Int, val result: PolicyResult) {
        val network: Long = ((a.toLong() shl 24) or (b.toLong() shl 16) or (c.toLong() shl 8) or d.toLong())
        val mask: Long = if (bits == 0) 0L else (0xFFFFFFFFL shl (32 - bits)) and 0xFFFFFFFFL
    }

    private val blocked = listOf(
        Range(0, 0, 0, 0, 8, PolicyResult.DENY_RESERVED),
        Range(10, 0, 0, 0, 8, PolicyResult.DENY_PRIVATE),
        Range(100, 64, 0, 0, 10, PolicyResult.DENY_SHARED),
        Range(127, 0, 0, 0, 8, PolicyResult.DENY_LOOPBACK),
        Range(169, 254, 0, 0, 16, PolicyResult.DENY_LINK_LOCAL),
        Range(172, 16, 0, 0, 12, PolicyResult.DENY_PRIVATE),
        Range(192, 0, 0, 0, 24, PolicyResult.DENY_RESERVED),
        Range(192, 0, 2, 0, 24, PolicyResult.DENY_DOCUMENTATION),
        Range(192, 168, 0, 0, 16, PolicyResult.DENY_PRIVATE),
        Range(198, 18, 0, 0, 15, PolicyResult.DENY_BENCHMARK),
        Range(198, 51, 100, 0, 24, PolicyResult.DENY_DOCUMENTATION),
        Range(203, 0, 113, 0, 24, PolicyResult.DENY_DOCUMENTATION),
        Range(224, 0, 0, 0, 4, PolicyResult.DENY_MULTICAST),
        Range(240, 0, 0, 0, 4, PolicyResult.DENY_RESERVED),
    )

    fun evaluate(address: InetAddress): PolicyResult =
        if (address is Inet4Address) evaluate(address.address) else PolicyResult.UNSUPPORTED_ADDRESS_FAMILY

    fun evaluate(bytes: ByteArray): PolicyResult {
        if (bytes.size != 4) return PolicyResult.UNSUPPORTED_ADDRESS_FAMILY
        val value = ((bytes[0].toLong() and 0xFF) shl 24) or ((bytes[1].toLong() and 0xFF) shl 16) or
            ((bytes[2].toLong() and 0xFF) shl 8) or (bytes[3].toLong() and 0xFF)
        for (range in blocked) if ((value and range.mask) == range.network) return range.result
        return PolicyResult.ALLOW
    }

    /** Keeps allowed addresses in resolver order; throws when nothing usable remains. [domain] is never logged. */
    fun filterResolved(@Suppress("UNUSED_PARAMETER") domain: String, addresses: List<InetAddress>): List<InetAddress> {
        var firstDenial: PolicyResult? = null
        val allowed = addresses.filter { address ->
            val result = evaluate(address)
            if (!result.allowed && firstDenial == null) firstDenial = result
            result.allowed
        }
        if (allowed.isEmpty()) throw DestinationDeniedException(firstDenial ?: PolicyResult.DENY_RESERVED)
        return allowed
    }

    /** Re-check the exact address handed to Socket.connect(); guards against DNS rebinding between resolve and connect. */
    fun requireAllowed(address: InetAddress) {
        val result = evaluate(address)
        if (!result.allowed) throw DestinationDeniedException(result)
    }
}
