package io.droidbridge.network

data class SocketEgressPolicy(val ipv4Ttl: Int? = null,val ipv6HopLimit: Int? = null) {
    init { require(ipv4Ttl == null || ipv4Ttl in 1..255); require(ipv6HopLimit == null || ipv6HopLimit in 1..255) }
}

class SocketPolicyException : java.io.IOException("socket TTL/Hop Limit could not be applied and verified")
