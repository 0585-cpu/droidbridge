package io.droidbridge.util

/**
 * Minimal JSON for pairing frames and test fixtures (org.json is unavailable in plain JVM unit tests).
 * Objects → Map, arrays → List, integers → Long, other numbers → Double. Encoding sorts keys (canonical form).
 */
object Json {
    fun parse(text: String): Any? {
        val parser = Parser(text)
        val value = parser.value()
        parser.skipWs()
        if (!parser.atEnd()) throw IllegalArgumentException("trailing data")
        return value
    }

    fun parseObject(text: String): Map<String, Any?> {
        @Suppress("UNCHECKED_CAST")
        return parse(text) as? Map<String, Any?> ?: throw IllegalArgumentException("expected object")
    }

    fun encode(value: Any?): String = StringBuilder().also { encodeTo(it, value) }.toString()

    private fun encodeTo(sb: StringBuilder, value: Any?) {
        when (value) {
            null -> sb.append("null")
            is Boolean, is Int, is Long -> sb.append(value.toString())
            is String -> encodeString(sb, value)
            is Map<*, *> -> {
                sb.append('{')
                value.entries.sortedBy { it.key as String }.forEachIndexed { i, (k, v) ->
                    if (i > 0) sb.append(',')
                    encodeString(sb, k as String)
                    sb.append(':')
                    encodeTo(sb, v)
                }
                sb.append('}')
            }
            is List<*> -> {
                sb.append('[')
                value.forEachIndexed { i, v ->
                    if (i > 0) sb.append(',')
                    encodeTo(sb, v)
                }
                sb.append(']')
            }
            else -> throw IllegalArgumentException("unsupported json value ${value::class}")
        }
    }

    private fun encodeString(sb: StringBuilder, s: String) {
        sb.append('"')
        for (c in s) when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c < ' ' -> sb.append(String.format("\\u%04x", c.code))
            else -> sb.append(c)
        }
        sb.append('"')
    }

    private class Parser(private val s: String) {
        private var i = 0

        fun atEnd() = i >= s.length
        fun skipWs() { while (i < s.length && s[i].isWhitespace()) i++ }
        private fun peek(): Char = if (i < s.length) s[i] else throw IllegalArgumentException("unexpected end")

        fun value(): Any? {
            skipWs()
            return when (peek()) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> num()
            }
        }

        private fun literal(word: String, v: Any?): Any? {
            if (!s.startsWith(word, i)) throw IllegalArgumentException("bad literal")
            i += word.length
            return v
        }

        private fun expect(c: Char) {
            if (peek() != c) throw IllegalArgumentException("expected $c")
            i++
        }

        private fun obj(): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            i++
            skipWs()
            if (peek() == '}') { i++; return out }
            while (true) {
                skipWs()
                val key = str()
                skipWs()
                expect(':')
                out[key] = value()
                skipWs()
                if (peek() == ',') { i++; continue }
                expect('}')
                return out
            }
        }

        private fun arr(): List<Any?> {
            val out = ArrayList<Any?>()
            i++
            skipWs()
            if (peek() == ']') { i++; return out }
            while (true) {
                out += value()
                skipWs()
                if (peek() == ',') { i++; continue }
                expect(']')
                return out
            }
        }

        private fun str(): String {
            expect('"')
            val sb = StringBuilder()
            while (peek() != '"') {
                if (s[i] == '\\') {
                    i++
                    when (peek()) {
                        'n' -> sb.append('\n')
                        't' -> sb.append('\t')
                        'r' -> sb.append('\r')
                        'u' -> { sb.append(s.substring(i + 1, i + 5).toInt(16).toChar()); i += 4 }
                        else -> sb.append(s[i])
                    }
                } else {
                    sb.append(s[i])
                }
                i++
            }
            i++
            return sb.toString()
        }

        private fun num(): Any {
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] in "-+.eE")) i++
            val t = s.substring(start, i)
            if (t.isEmpty()) throw IllegalArgumentException("unexpected character")
            return if (t.any { it in ".eE" }) t.toDouble() else t.toLong()
        }
    }
}
