package io.droidbridge.protocol

import io.droidbridge.util.Json

object TestJson {
    fun loadResource(name: String): Map<*, *> {
        val text = requireNotNull(TestJson::class.java.classLoader?.getResourceAsStream(name)) { "missing $name" }
            .bufferedReader().readText()
        return Json.parseObject(text)
    }
}
