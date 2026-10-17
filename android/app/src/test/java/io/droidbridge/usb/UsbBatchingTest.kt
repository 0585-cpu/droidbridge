package io.droidbridge.usb

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import kotlin.test.*

class UsbBatchingTest {
    private val epoch = ByteArray(16)
    private fun ready() = ReliableUsbState(null, 0).also {
        it.receive(ReliableUsbRecord(1, epoch), 0); it.next(0)
    }
    @Test fun isolatedDataHasABoundedAckDelayAndNoIdleTimer() {
        val state = ready()
        state.receive(ReliableUsbRecord(3,epoch,1,payload=byteArrayOf(7)),100)
        assertNull(state.next(100))
        assertEquals(102L,state.nextWakeAt(100))
        assertNull(state.next(101))
        assertEquals(1L,state.next(102)!!.ack)
        assertNull(state.nextWakeAt(102))
    }
    @Test fun eighthRecordFlushesAckWithoutExtendingFirstDeadline() {
        val state = ready()
        repeat(7) { state.receive(ReliableUsbRecord(3,epoch,it+1L,payload=byteArrayOf(7)),100) }
        assertNull(state.next(100))
        assertEquals(102L,state.nextWakeAt(100))
        state.receive(ReliableUsbRecord(3,epoch,8,payload=byteArrayOf(7)),101)
        assertEquals(8L,state.next(101)!!.ack)
        assertNull(state.next(101))
    }
    @Test fun duplicatesGapsAndRefusalImmediatelyReportOnlyAcceptedSequence() {
        for (sequence in listOf(1L,3L,2L)) {
            val state=ready()
            state.receive(ReliableUsbRecord(3,epoch,1,payload=byteArrayOf(7)),100)
            state.receive(ReliableUsbRecord(3,epoch,sequence,payload=byteArrayOf(9)),101,
                acceptPayload=sequence!=2L)
            assertEquals(1L,state.next(101)!!.ack)
        }
    }
    @Test fun pendingDataPiggybacksAndCancelsDelayedAck() {
        val state=ready()
        state.receive(ReliableUsbRecord(3,epoch,1,payload=byteArrayOf(7)),100)
        assertTrue(state.offer(byteArrayOf(9),101))
        val data=state.next(101)!!
        assertEquals(3,data.kind);assertEquals(1L,data.ack)
        assertNull(state.next(102))
        state.receive(ReliableUsbRecord(4,epoch,ack=1),103)
        assertNull(state.nextWakeAt(103))
    }
    @Test fun frameReaderUsesBulkReadsAndStillRejectsTruncatedHeaders() {
        val encoded=AoaFrame(AoaFrame.DATA,1,payload=byteArrayOf(1,2,3)).encode()
        fun source(bytes: ByteArray)=object:ByteArrayInputStream(bytes) {
            override fun read(): Int = error("scalar read allocates in reliable channel")
            override fun read(b: ByteArray,off: Int,len: Int): Int = super.read(b,off,minOf(3,len))
        }
        val input=source(encoded)
        assertContentEquals(byteArrayOf(1,2,3),AoaFrame.read(input)!!.payload)
        assertNull(AoaFrame.read(input))
        assertFailsWith<EOFException> { AoaFrame.read(source(encoded.copyOf(10))) }
    }
    @Test fun alignedFrameMakesOneDescriptorWriteThroughReliableChannel() {
        ServerSocket(0).use { listener -> Socket("127.0.0.1",listener.localPort).use { host ->
            val accessory=listener.accept()
            val writes=LinkedBlockingQueue<ByteArray>()
            val rawOutput=object:OutputStream() {
                override fun write(b:Int)=error("bulk writes only")
                override fun write(b:ByteArray,off:Int,len:Int) { writes.add(b.copyOfRange(off,off+len)) }
            }
            val channel=ReliableAccessoryChannel(accessory.getInputStream(),rawOutput,{accessory.close()})
            try {
                host.getOutputStream().write(ReliableUsbRecord(1,epoch).encode())
                val helloAck=assertNotNull(writes.poll(2,TimeUnit.SECONDS))
                assertEquals(2,ReliableUsbDecoder().append(helloAck).single().kind)
                val payload=ByteArray(AoaFrame.SEND_PAYLOAD) { (it*7).toByte() }
                val encoded=AoaFrame(AoaFrame.DATA,1,payload=payload).encode()
                channel.output.write(encoded)
                val raw=assertNotNull(writes.poll(2,TimeUnit.SECONDS))
                assertEquals(16384,raw.size,"one full raw write includes both framing headers")
                val record=ReliableUsbDecoder().append(raw).single()
                assertEquals(3,record.kind)
                assertContentEquals(encoded,record.payload)
                host.getOutputStream().write(ReliableUsbRecord(4,epoch,ack=record.sequence).encode())
                assertContentEquals(payload,AoaFrame.read(ByteArrayInputStream(record.payload))!!.payload)
            } finally { channel.close() }
        } }
    }
    @Test fun socketFramesRespectAlignedPayloadBudget() {
        ServerSocket(0).use { usb -> Socket("127.0.0.1",usb.localPort).use { host ->
            host.soTimeout=5000
            val accessory=usb.accept()
            ServerSocket(0).use { relay ->
                relay.soTimeout=5000
                val bridge=AoaAccessoryBridge(accessory.getInputStream(),accessory.getOutputStream(),
                    relay.localPort,relay.localPort,{accessory.close()})
                bridge.start()
                try {
                    fun send(f:AoaFrame)=host.getOutputStream().write(f.encode())
                    send(AoaFrame(AoaFrame.RESET,0,payload=ByteArray(16)))
                    assertEquals(AoaFrame.RESET_OK,AoaFrame.read(host.getInputStream())!!.type)
                    send(AoaFrame(AoaFrame.OPEN,1,AoaFrame.RELAY))
                    relay.accept().use { peer ->
                        assertEquals(AoaFrame.OPEN_OK,AoaFrame.read(host.getInputStream())!!.type)
                        val body=ByteArray(65536) { (it*7).toByte() }
                        peer.getOutputStream().write(body)
                        val received=ByteArrayOutputStream()
                        var frames=0
                        while(received.size()<body.size) {
                            val frame=AoaFrame.read(host.getInputStream())!!
                            assertEquals(AoaFrame.DATA,frame.type)
                            assertTrue(frame.payload.size<=16288,"payload ${frame.payload.size} exceeds one raw write budget")
                            received.write(frame.payload);frames++
                            send(AoaFrame.window(1,received.size().toLong()))
                        }
                        assertContentEquals(body,received.toByteArray())
                        println("65536 socket bytes delivered in $frames bounded DATA frames")
                    }
                } finally { bridge.close() }
            }
        } }
    }
    @Test fun framesQueuedBehindAWriteShareOneRecord() {
        ServerSocket(0).use { usb -> Socket("127.0.0.1",usb.localPort).use { host ->
            val accessory=usb.accept()
            val gate=CountDownLatch(1)
            val writes=LinkedBlockingQueue<ByteArray>()
            val output=object:OutputStream() {
                override fun write(b:Int)=error("bulk writes only")
                override fun write(b:ByteArray,off:Int,len:Int) {
                    writes.add(b.copyOfRange(off,off+len)); gate.await(5,TimeUnit.SECONDS)
                }
            }
            val bridge=AoaAccessoryBridge(accessory.getInputStream(),output,closeTransport={accessory.close()})
            bridge.start()
            try {
                fun send(f:AoaFrame)=host.getOutputStream().write(f.encode())
                send(AoaFrame(AoaFrame.RESET,0,payload=ByteArray(16)))
                val first=assertNotNull(writes.poll(2,TimeUnit.SECONDS)) // writer now blocked in it
                assertEquals(AoaFrame.RESET_OK,AoaFrame.read(ByteArrayInputStream(first))!!.type)
                repeat(5) { send(AoaFrame(AoaFrame.PING,0)) }
                Thread.sleep(300) // let the selector queue all five PONGs behind the blocked write
                gate.countDown()
                val batch=assertNotNull(writes.poll(2,TimeUnit.SECONDS))
                assertTrue(batch.size<=AoaFrame.WRITE_BUDGET)
                val input=ByteArrayInputStream(batch)
                assertEquals(List(5){AoaFrame.PONG},generateSequence{AoaFrame.read(input)}.map{it.type}.toList(),
                    "queued frames must leave in one write, not one record each")
            } finally { bridge.close() }
        } }
    }
    @Test fun backloggedWriterDoesNotSpinTheSelector() {
        ServerSocket(0).use { usb -> Socket("127.0.0.1",usb.localPort).use { host ->
            val accessory=usb.accept()
            val gate=CountDownLatch(1)
            val output=object:OutputStream() {
                override fun write(b:Int)=error("bulk writes only")
                override fun write(b:ByteArray,off:Int,len:Int) { gate.await(10,TimeUnit.SECONDS) }
            }
            ServerSocket(0,128).use { relay ->
                relay.soTimeout=5000
                val bridge=AoaAccessoryBridge(accessory.getInputStream(),output,relay.localPort,relay.localPort,{accessory.close()})
                bridge.start()
                val peers=ArrayList<Socket>()
                try {
                    host.getOutputStream().write(AoaFrame(AoaFrame.RESET,0,payload=ByteArray(16)).encode())
                    // 70 streams x 64 KiB of credit is far beyond the 256-frame read high water.
                    // Open every stream before any data: a backlog defers USB frames such as OPEN.
                    repeat(70) { index ->
                        host.getOutputStream().write(AoaFrame(AoaFrame.OPEN,index*2+1,AoaFrame.RELAY).encode())
                        peers += relay.accept()
                    }
                    peers.forEach { it.getOutputStream().write(ByteArray(65536)) }
                    Thread.sleep(1000) // reach the backlog with readable sockets still pending
                    val selectorThread=Thread.getAllStackTraces().keys.single { it.name=="aoa-sockets" }
                    val cpu=java.lang.management.ManagementFactory.getThreadMXBean()
                    val before=cpu.getThreadCpuTime(selectorThread.id)
                    Thread.sleep(1000)
                    val used=(cpu.getThreadCpuTime(selectorThread.id)-before)/1_000_000
                    println("selector CPU while USB writer is blocked: ${used} ms per second")
                    assertTrue(used<200,"selector spins while paused by the writer backlog: ${used} ms/s")
                } finally { gate.countDown(); peers.forEach { it.close() }; bridge.close() }
            }
        } }
    }
}
