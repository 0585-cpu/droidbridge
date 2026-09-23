package io.droidbridge.network

import java.io.Closeable
import java.util.IdentityHashMap

/** Keeps API26–28 borrowed descriptor wrappers alive until their owning socket is closed.
 * Closing or detaching those wrappers while live mutates the socket's original FileDescriptor. */
internal class SocketDescriptorOwnership {
    private val retained=IdentityHashMap<Closeable,MutableList<Closeable>>()
    fun <T: Closeable,R> useDuplicate(owner: Closeable,wrapper: T,borrowed: Boolean,duplicate: (T) -> T,action: (T) -> R): R {
        if(borrowed) synchronized(retained) { retained.getOrPut(owner) { mutableListOf() }.add(wrapper) }
        try { return duplicate(wrapper).use(action) }
        finally { if(!borrowed) wrapper.close() }
    }
    fun release(owner: Closeable) {
        // Owner close invalidates the shared FileDescriptor object before wrapper cleanup.
        runCatching { owner.close() }
        val wrappers=synchronized(retained) { retained.remove(owner) }.orEmpty()
        wrappers.forEach { runCatching { it.close() } }
    }
}
