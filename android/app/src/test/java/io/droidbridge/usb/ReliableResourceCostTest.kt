package io.droidbridge.usb

import java.io.InputStream
import java.io.OutputStream
import java.lang.management.ManagementFactory
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.test.*

class ReliableResourceCostTest {
    @Test fun smallRecordEncodingAvoidsPerPacketDigestProviderAllocation() {
        val bean=ManagementFactory.getThreadMXBean() as? com.sun.management.ThreadMXBean
        org.junit.Assume.assumeTrue(bean?.isThreadAllocatedMemorySupported==true)
        bean!!.isThreadAllocatedMemoryEnabled=true
        val record=ReliableUsbRecord(3,ByteArray(16),1,payload=ByteArray(512){7})
        repeat(500) { record.encode() }
        val start=bean.getThreadAllocatedBytes(Thread.currentThread().id)
        var total=0
        repeat(4096) { total+=record.encode().size }
        val allocated=bean.getThreadAllocatedBytes(Thread.currentThread().id)-start
        println("record_encode payload=2MiB wireBytes=$total allocatedBytes=$allocated")
        assertEquals(4096*592,total)
        assertTrue(allocated<4L*1024*1024,"Small records allocate excessive provider and header objects: $allocated")
    }

    @Test fun untouchedAccessoryDoesNotPollWriterAndWatchdog() {
        val closed=CountDownLatch(1)
        val before=Thread.getAllStackTraces().keys.map { it.id }.toSet()
        val channel=ReliableAccessoryChannel(object : InputStream() {
            override fun read(): Int { closed.await(5,TimeUnit.SECONDS); return -1 }
        },object : OutputStream() { override fun write(b: Int)=error("No writes before host HELLO") },{closed.countDown()})
        val bean=ManagementFactory.getThreadMXBean()
        try {
            Thread.sleep(100)
            val workers=Thread.getAllStackTraces().keys.filter { it.id !in before && it.name.startsWith("aoa-reliable-") }
            val baseline=workers.associate { it.id to (bean.getThreadInfo(it.id)?.waitedCount ?: 0) }
            Thread.sleep(1100)
            val wakeups=workers.sumOf { ((bean.getThreadInfo(it.id)?.waitedCount ?: 0)-(baseline[it.id] ?: 0)).coerceAtLeast(0) }
            println("unused_accessory timed_or_notified_waits_in_1100ms=$wakeups")
            assertTrue(wakeups<=1,"No host, packets or deadline exist, but idle workers poll: $wakeups")
        } finally { channel.close() }
    }
}
