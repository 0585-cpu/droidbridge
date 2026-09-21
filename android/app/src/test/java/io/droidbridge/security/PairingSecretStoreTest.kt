package io.droidbridge.security

import android.content.SharedPreferences
import io.droidbridge.pairing.PairedPeer
import java.util.Base64
import javax.crypto.KeyGenerator
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** Minimal SharedPreferences fake: only the string operations the store uses. */
class FakePrefs : SharedPreferences {
    val values = HashMap<String, String>()
    var commits = 0

    override fun getAll(): MutableMap<String, *> = HashMap(values)
    override fun getString(key: String?, defValue: String?): String? = values[key] ?: defValue
    override fun getStringSet(key: String?, defValues: MutableSet<String>?) = defValues
    override fun getInt(key: String?, defValue: Int) = defValue
    override fun getLong(key: String?, defValue: Long) = defValue
    override fun getFloat(key: String?, defValue: Float) = defValue
    override fun getBoolean(key: String?, defValue: Boolean) = defValue
    override fun contains(key: String?) = values.containsKey(key)
    override fun registerOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}
    override fun unregisterOnSharedPreferenceChangeListener(l: SharedPreferences.OnSharedPreferenceChangeListener?) {}

    override fun edit(): SharedPreferences.Editor = object : SharedPreferences.Editor {
        private val pending = HashMap<String, String?>()
        private var clearAll = false
        override fun putString(key: String?, value: String?) = apply { pending[key!!] = value }
        override fun putStringSet(key: String?, values: MutableSet<String>?) = this
        override fun putInt(key: String?, value: Int) = this
        override fun putLong(key: String?, value: Long) = this
        override fun putFloat(key: String?, value: Float) = this
        override fun putBoolean(key: String?, value: Boolean) = this
        override fun remove(key: String?) = apply { pending[key!!] = null }
        override fun clear() = apply { clearAll = true }
        override fun commit(): Boolean {
            if (clearAll) values.clear()
            for ((k, v) in pending) if (v == null) values.remove(k) else values[k] = v
            commits++
            return true
        }
        override fun apply() { commit() }
    }
}

class PairingSecretStoreTest {
    private val key = KeyGenerator.getInstance("AES").also { it.init(256) }.generateKey()
    private val prefs = FakePrefs()
    private val store = AndroidPairingSecretStore(prefs) { key }

    @Test
    fun `empty store loads null`() {
        assertNull(store.load())
    }

    @Test
    fun `replace persists encrypted and load round trips`() {
        val secret = ByteArray(32) { it.toByte() }
        store.replace(PairedPeer("mac-1", "MacBook", secret))
        val loaded = store.load()!!
        assertEquals("mac-1", loaded.peerId)
        assertEquals("MacBook", loaded.displayName)
        assertContentEquals(secret, loaded.secret)
        val blob = prefs.values.getValue("peer.v1")
        assertFalse(blob.contains(Base64.getEncoder().encodeToString(secret).take(12)))
        assertTrue(prefs.values.values.none { it.contains("MacBook") })
    }

    @Test
    fun `new peer atomically replaces old peer in one commit`() {
        store.replace(PairedPeer("mac-1", "Old", ByteArray(32) { 1 }))
        val before = prefs.commits
        store.replace(PairedPeer("mac-2", "New", ByteArray(32) { 2 }))
        assertEquals(before + 1, prefs.commits)
        assertEquals("mac-2", store.load()!!.peerId)
        assertEquals(2, prefs.values.size)
    }

    @Test
    fun `tampered blob or peer id fails closed`() {
        store.replace(PairedPeer("mac-1", "Mac", ByteArray(32) { 1 }))
        val original = prefs.values.getValue("peer.v1")
        prefs.values["peer.id"] = "mac-9" // AAD mismatch
        assertNull(store.load())
        prefs.values["peer.id"] = "mac-1"
        val bytes = Base64.getDecoder().decode(original)
        bytes[bytes.size - 1] = (bytes[bytes.size - 1] + 1).toByte()
        prefs.values["peer.v1"] = Base64.getEncoder().encodeToString(bytes)
        assertNull(store.load())
    }

    @Test
    fun `clear removes everything and rejects bad secrets`() {
        store.replace(PairedPeer("mac-1", "Mac", ByteArray(32) { 1 }))
        store.clear()
        assertNull(store.load())
        assertTrue(prefs.values.isEmpty())
        assertFailsWith<IllegalArgumentException> { PairedPeer("x", "y", ByteArray(31)) }
    }
}
