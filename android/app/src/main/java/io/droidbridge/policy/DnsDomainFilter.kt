package io.droidbridge.policy

import java.util.Locale

class DnsDomainFilter(suffixes: List<String>) {
    private val suffixes = suffixes.map(::normalize).also { entries ->
        require(entries.size <= 256)
        require(entries.all { it.length in 1..253 && it.split('.').all { label -> label.length in 1..63 && label.all { c -> c in 'a'..'z' || c in '0'..'9' || c == '-' || c == '_' } } })
    }
    fun blocks(name: String): Boolean { val normalized=normalize(name); return suffixes.any { normalized == it || normalized.endsWith(".$it") } }
    companion object { fun normalize(name: String): String = name.trim().trimEnd('.').lowercase(Locale.ROOT) }
}
