package io.droidbridge.usb

import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.net.ServerSocket
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.test.*

class ReliableAccessoryChannelTest {
    @Test fun pausedApplicationReaderDoesNotBlockPeerAcknowledgements() {
        ServerSocket(0).use { listener -> Socket("127.0.0.1",listener.localPort).use { host ->
            val phone=listener.accept()
            host.soTimeout=100
            val channel=ReliableAccessoryChannel(phone.getInputStream(),phone.getOutputStream(),{ phone.close() })
            val epoch=ByteArray(16)
            val failure=AtomicReference<Throwable?>()
            val sent=CountDownLatch(1)
            val body=ByteArray(1024*1024) { 31 }
            try {
                host.getOutputStream().write(ReliableUsbRecord(1,epoch).encode())
                host.getOutputStream().write(ReliableUsbRecord(3,epoch,1,payload=byteArrayOf(42)).encode())
                assertEquals(42,channel.input.read())
                // Stop consuming application bytes. Raw ACKs must still reach the opposite writer.
                val writer=thread(isDaemon=true) {
                    try { channel.output.write(body) } catch (e: Throwable) { failure.set(e) }
                    finally { sent.countDown() }
                }
                val decoder=ReliableUsbDecoder()
                val received=ByteArrayOutputStream()
                val bytes=ByteArray(16384)
                var nextHost=2L
                var receivedSequence=0L
                var acknowledged=0L
                val deadline=System.nanoTime()+3_000_000_000L
                while (System.nanoTime()<deadline && (received.size()<body.size || nextHost<=40 || acknowledged<33)) {
                    // Within the sender's 32-record reliable window; fill the receiver queue.
                    if (nextHost<=40 && nextHost-acknowledged<=32) {
                        host.getOutputStream().write(ReliableUsbRecord(3,epoch,nextHost++,receivedSequence,ByteArray(16384){9}).encode())
                    }
                    try {
                        val n=host.getInputStream().read(bytes)
                        if(n<0) break
                        for(record in decoder.append(bytes.copyOf(n))) {
                            acknowledged=maxOf(acknowledged,record.ack)
                            if(record.kind==3 && record.sequence==receivedSequence+1) {
                                receivedSequence++; received.write(record.payload)
                            }
                            if(record.kind==3) host.getOutputStream().write(ReliableUsbRecord(4,epoch,ack=receivedSequence).encode())
                        }
                    } catch (_: SocketTimeoutException) { }
                }
                assertTrue(sent.await(100,TimeUnit.MILLISECONDS),"Outbound writer cannot consume ACKs while application reader pauses")
                failure.get()?.let { throw AssertionError(it) }
                assertContentEquals(body,received.toByteArray())
                assertEquals(33L,acknowledged,"Only the bounded 512KiB receive queue may be acknowledged")
                // Draining the queue then retrying the next unacknowledged record recovers exactly.
                val drained=ByteArray(32*16384)
                java.io.DataInputStream(channel.input).readFully(drained)
                assertTrue(drained.all { it==9.toByte() })
                host.getOutputStream().write(ReliableUsbRecord(3,epoch,34,receivedSequence,byteArrayOf(7)).encode())
                assertEquals(7,channel.input.read())
                writer.join(1000)
            } finally { channel.close() }
        } }
    }

    @Test fun duplexLossAndDuplicatesDeliverTheExactMultiWindowBody() {
        val server = ServerSocket(0)
        val host = Socket("127.0.0.1",server.localPort)
        val phone = server.accept(); server.close()
        host.soTimeout = 20
        val phoneOut = phone.getOutputStream()
        // Accumulate the channel's 16KiB writes, then damage records as the USB path did.
        val faulty = object : OutputStream() {
            val decoder = ReliableUsbDecoder()
            var lostAck = false
            var lostData = false
            var duplicate = false
            override fun write(b: Int) = write(byteArrayOf(b.toByte()))
            override fun write(b: ByteArray, off: Int, len: Int) {
                decoder.append(b.copyOfRange(off,off+len)).forEach { record ->
                    if (record.kind == 4 && !lostAck) { lostAck = true; return@forEach }
                    val bytes = record.encode()
                    if (record.kind == 3 && !lostData) {
                        lostData = true; phoneOut.write(bytes,1024,bytes.size-1024)
                    } else {
                        phoneOut.write(bytes)
                        if (record.kind == 3 && !duplicate) { duplicate = true; phoneOut.write(bytes) }
                    }
                }
            }
        }
        val channel = ReliableAccessoryChannel(phone.getInputStream(),faulty,{ phone.close() })
        val payload = ByteArray(1_048_576) { (it*13).toByte() }
        val error = AtomicReference<Throwable?>()
        val done = CountDownLatch(3)
        val hostFinished = CountDownLatch(1)
        fun worker(work: () -> Unit) = thread(isDaemon=true) {
            try { work() } catch (failure: Throwable) { error.compareAndSet(null,failure) } finally { done.countDown() }
        }
        worker { channel.output.write(payload) }
        worker {
            val received = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            while (received.size() < payload.size) {
                val count = channel.input.read(buf)
                check(count > 0); received.write(buf,0,count)
            }
            assertContentEquals(payload,received.toByteArray())
            // The production AOA reader keeps draining control records. Ending this fixture's
            // reader after one payload can strand ACKs for the still-running opposite writer.
            try { assertEquals(-1, channel.input.read(), "unexpected extra payload") }
            catch (failure: IOException) { if (hostFinished.count != 0L) throw failure }
        }
        worker {
            try {
            val now = { System.nanoTime()/1_000_000 }
            val state = ReliableUsbState(ByteArray(16){it.toByte()},now())
            val decoder = ReliableUsbDecoder()
            val received = ByteArrayOutputStream()
            var pos = 0
            var offeredRecords = 0L
            var hostDataAcknowledged = 0L
            var lostData = false
            var lostAck = false
            val buffer = ByteArray(16384)
            val deadline = now()+9000
            // Enqueueing the final host chunk does not prove the phone received it.
            // Keep serving retransmissions until its cumulative ACK confirms delivery.
            while ((received.size() < payload.size || pos < payload.size || hostDataAcknowledged < offeredRecords)
                && now() < deadline) {
                if (pos < payload.size) {
                    val end = minOf(pos+16384,payload.size)
                    if (state.offer(payload.copyOfRange(pos,end),now())) { pos=end; offeredRecords++ }
                }
                // Drain each ready batch; keep reading to prevent full duplex IO starvation.
                repeat(40) {
                    state.next(now())?.let { record ->
                        val bytes = record.encode()
                        if (record.kind == 3 && !lostData) {
                            lostData=true; host.getOutputStream().write(bytes,1024,bytes.size-1024)
                        } else if (record.kind == 4 && !lostAck) { lostAck=true }
                        else host.getOutputStream().write(bytes)
                    }
                }
                try {
                    val count = host.getInputStream().read(buffer)
                    if (count < 0) throw IOException("test peer closed")
                    decoder.append(buffer.copyOf(count)).forEach { record ->
                        state.receive(record,now())?.let { received.write(it) }
                        if (record.kind == 3 || record.kind == 4) hostDataAcknowledged = maxOf(hostDataAcknowledged,record.ack)
                    }
                } catch (_: SocketTimeoutException) {}
            }
            // Flush the final receive ACK before the reader exits.
            state.next(now())?.let { host.getOutputStream().write(it.encode()) }
            assertContentEquals(payload,received.toByteArray())
            assertEquals(offeredRecords,hostDataAcknowledged, "Host must not leave before its last DATA is delivered")
            } finally {
                hostFinished.countDown()
                channel.close()
            }
        }
        try {
            assertTrue(done.await(10,TimeUnit.SECONDS), "duplex workers stalled")
            error.get()?.let { throw AssertionError("duplex failure",it) }
        } finally { channel.close(); host.close() }
    }

    @Test fun blockedRawWriteHasAnIndependentDeadline() {
        val closed = CountDownLatch(1)
        val entered = CountDownLatch(1)
        val hello = ReliableUsbRecord(1,ByteArray(16)).encode()
        val rawIn = object : java.io.InputStream() {
            var sent = false
            override fun read(): Int = error("bulk reads only")
            override fun read(b: ByteArray,off: Int,len: Int): Int {
                if (!sent) { sent=true; hello.copyInto(b,off); return hello.size }
                closed.await(12,TimeUnit.SECONDS); return -1
            }
        }
        val rawOut = object : OutputStream() {
            override fun write(b: Int) = error("bulk writes only")
            override fun write(b: ByteArray,off: Int,len: Int) {
                entered.countDown()
                closed.await(12,TimeUnit.SECONDS)
                throw IOException("descriptor closed")
            }
        }
        val reason = AtomicReference<String>()
        val diagnosed = CountDownLatch(1)
        val channel = ReliableAccessoryChannel(rawIn,rawOut,{closed.countDown()}, {_,text -> reason.set(text); diagnosed.countDown()},
            writeTimeoutMs = 2_000)
        val readerDone = CountDownLatch(1)
        thread(isDaemon=true) {
            try { channel.input.read() } catch (_: IOException) {} finally { readerDone.countDown() }
        }
        try {
            assertTrue(entered.await(1,TimeUnit.SECONDS))
            assertTrue(closed.await(4,TimeUnit.SECONDS), "watchdog did not close blocked descriptor")
            assertTrue(readerDone.await(1,TimeUnit.SECONDS))
            assertTrue(diagnosed.await(1,TimeUnit.SECONDS))
            assertEquals("USB bulk write timed out",reason.get())
        } finally { channel.close() }
    }

    @Test fun lateFirstHostConnectsThroughTheStillOpenDescriptor() {
        val server = ServerSocket(0)
        val host = Socket("127.0.0.1", server.localPort)
        val phone = server.accept(); server.close()
        host.soTimeout = 2000
        val closed = CountDownLatch(1)
        val received = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>()
        val channel = ReliableAccessoryChannel(phone.getInputStream(), phone.getOutputStream(), {
            phone.close(); closed.countDown()
        })
        thread(isDaemon=true) {
            try {
                assertEquals(42, channel.input.read())
                channel.output.write(byteArrayOf(8))
            } catch (error: Throwable) { failure.set(error) }
            finally { received.countDown() }
        }
        try {
            assertFalse(closed.await(11, TimeUnit.SECONDS), "initial host wait closed the descriptor")
            val epoch = ByteArray(16) { it.toByte() }
            host.getOutputStream().write(ReliableUsbRecord(1, epoch).encode())
            host.getOutputStream().write(ReliableUsbRecord(3, epoch, 1, payload=byteArrayOf(42)).encode())
            assertTrue(received.await(2, TimeUnit.SECONDS))
            failure.get()?.let { throw AssertionError("late host could not connect", it) }
            val decoder = ReliableUsbDecoder()
            val bytes = ByteArray(16384)
            var reply: ReliableUsbRecord? = null
            while (reply == null) {
                val n = host.getInputStream().read(bytes)
                assertTrue(n > 0)
                reply = decoder.append(bytes.copyOf(n)).firstOrNull { it.kind == 3 }
            }
            assertContentEquals(byteArrayOf(8), reply.payload)
            assertEquals(1L, reply.ack)
        } finally { channel.close(); host.close() }
        assertTrue(closed.await(1, TimeUnit.SECONDS))
    }

    @Test fun stopWakesAWriterWaitingForHandshake() {
        val server = ServerSocket(0)
        val peer = Socket("127.0.0.1",server.localPort)
        val socket = server.accept(); server.close()
        val channel = ReliableAccessoryChannel(socket.getInputStream(),socket.getOutputStream(),{socket.close()})
        val started = CountDownLatch(1)
        val done = CountDownLatch(1)
        val result = AtomicReference<Throwable?>()
        thread(isDaemon=true) {
            started.countDown()
            try { channel.output.write(byteArrayOf(1)) } catch (error: Throwable) { result.set(error) }
            finally { done.countDown() }
        }
        assertTrue(started.await(1,TimeUnit.SECONDS))
        channel.close()
        assertTrue(done.await(2,TimeUnit.SECONDS))
        assertIs<IOException>(result.get())
        peer.close()
    }
}
