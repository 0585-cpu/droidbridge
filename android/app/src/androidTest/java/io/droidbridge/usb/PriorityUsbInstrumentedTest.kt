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

class PriorityUsbInstrumentedTest {
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

}
