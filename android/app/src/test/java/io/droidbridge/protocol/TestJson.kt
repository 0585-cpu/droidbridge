package io.droidbridge.protocol

/** Minimal JSON reader for test fixtures. Objects → Map, arrays → List, numbers → Long/Double. */
object TestJson {
    fun parse(text: String): Any? = Parser(text).also { it.skipWs() }.value()

    fun loadResource(name: String): Map<*, *> {
        val text = requireNotNull(TestJson::class.java.classLoader?.getResourceAsStream(name)) { "missing $name" }
            .bufferedReader().readText()
        return parse(text) as Map<*, *>
    }

    private class Parser(private val s: String) {
        private var i = 0

        fun skipWs() { while (i < s.length && s[i].isWhitespace()) i++ }

        fun value(): Any? {
            skipWs()
            return when (s[i]) {
                '{' -> obj()
                '[' -> arr()
                '"' -> str()
                't' -> { i += 4; true }
                'f' -> { i += 5; false }
                'n' -> { i += 4; null }
                else -> num()
            }
        }

        private fun obj(): Map<String, Any?> {
            val out = LinkedHashMap<String, Any?>()
            i++
            skipWs()
            if (s[i] == '}') { i++; return out }
            while (true) {
                skipWs()
                val key = str()
                skipWs(); check(s[i] == ':'); i++
                out[key] = value()
                skipWs()
                if (s[i] == ',') { i++; continue }
                check(s[i] == '}'); i++
                return out
            }
        }

        private fun arr(): List<Any?> {
            val out = ArrayList<Any?>()
            i++
            skipWs()
            if (s[i] == ']') { i++; return out }
            while (true) {
                out += value()
                skipWs()
                if (s[i] == ',') { i++; continue }
                check(s[i] == ']'); i++
                return out
            }
        }

        private fun str(): String {
            check(s[i] == '"'); i++
            val sb = StringBuilder()
            while (s[i] != '"') {
                if (s[i] == '\\') {
                    i++
                    sb.append(when (s[i]) { 'n' -> '\n'; 't' -> '\t'; 'u' -> { val c = s.substring(i + 1, i + 5).toInt(16).toChar(); i += 4; c }; else -> s[i] })
                } else sb.append(s[i])
                i++
            }
            i++
            return sb.toString()
        }

        private fun num(): Any {
            val start = i
            while (i < s.length && (s[i].isDigit() || s[i] in "-+.eE")) i++
            val t = s.substring(start, i)
            return if (t.any { it in ".eE" }) t.toDouble() else t.toLong()
        }
    }
}
