package io.droidbridge.relay

import kotlinx.coroutines.runBlocking
import org.junit.Test
import kotlin.test.*

class BoundedPacketQueueTest {
    @Test fun takeAllDrainsABurstInOrderWithinTheByteBudget() = runBlocking {
        val queue=BoundedDatagramQueue { fail("no drops expected") }
        repeat(5) { queue.offer(ByteArray(10) { _ -> it.toByte() }) }
        assertEquals(listOf<Byte>(0,1), queue.takeAll(25)!!.map { it[0] }, "stops before exceeding the budget")
        assertEquals(listOf<Byte>(2,3,4), queue.takeAll(100)!!.map { it[0] }, "keeps order across batches")
        queue.offer(ByteArray(40))
        assertEquals(1, queue.takeAll(25)!!.size, "an oversized head still makes progress")
        queue.close()
        assertNull(queue.takeAll(25))
    }
}
