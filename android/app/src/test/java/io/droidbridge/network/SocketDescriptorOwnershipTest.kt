package io.droidbridge.network

import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable

/** Models API26–28 PFD wrapping exactly the original FileDescriptor object. */
class SocketDescriptorOwnershipTest {
    private class Owner : Closeable {
        var valid=true
        override fun close() { valid=false }
    }
    private class Descriptor(private val owner: Owner?,private val events: MutableList<String>) : Closeable {
        var closed=false
        override fun close() { closed=true; if(owner!=null) { events+="borrowed-close:${owner.valid}"; owner.valid=false } else events+="duplicate-close" }
        fun duplicate()=Descriptor(null,events)
    }
    @Test fun `borrowed wrapper survives repeated duplicate work until owner is closed`() {
        val ownership=SocketDescriptorOwnership()
        val owner=Owner(); val events=mutableListOf<String>()
        val first=Descriptor(owner,events); val second=Descriptor(owner,events)
        for(descriptor in listOf(first,second)) {
            ownership.useDuplicate(owner,descriptor,true,Descriptor::duplicate) { assertFalse(it.closed) }
            assertTrue("applying options must preserve original FD",owner.valid)
            assertFalse(descriptor.closed)
        }
        assertEquals(listOf("duplicate-close","duplicate-close"),events)
        ownership.release(owner)
        assertFalse(owner.valid)
        assertEquals(listOf("duplicate-close","duplicate-close","borrowed-close:false","borrowed-close:false"),events)
    }
    @Test fun `duplicate failure retains borrowed wrapper until cleanup and owned wrapper closes immediately`() {
        val ownership=SocketDescriptorOwnership(); val owner=Owner(); val events=mutableListOf<String>()
        val borrowed=Descriptor(owner,events)
        assertThrows(java.io.IOException::class.java) { ownership.useDuplicate(owner,borrowed,true,{throw java.io.IOException("dup")}) { } }
        assertTrue(owner.valid); assertFalse(borrowed.closed)
        ownership.release(owner); assertTrue(borrowed.closed)
        val independent=Descriptor(null,events)
        ownership.useDuplicate(Owner(),independent,false,Descriptor::duplicate) { }
        assertTrue(independent.closed)
    }
}
