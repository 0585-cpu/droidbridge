package io.droidbridge.network

import io.droidbridge.protocol.OpenDestination
import java.net.InetAddress

/** Policy-filtered connect candidates for one OPEN_TCP. Each address is re-checked at connect time. */
class ResolvedDestination(val request: OpenDestination, val candidates: List<InetAddress>) {
    init { require(candidates.isNotEmpty()) }
    val port: Int get() = request.port
    override fun toString(): String = "ResolvedDestination(port=$port, candidates=${candidates.size})"
}
