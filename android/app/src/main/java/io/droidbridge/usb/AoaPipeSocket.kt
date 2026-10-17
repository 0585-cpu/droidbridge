package io.droidbridge.usb

import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.Socket
import java.net.SocketTimeoutException
import java.util.ArrayDeque

/**
 * One AOA relay stream handed to RelayServer in memory instead of through a loopback socket.
 * Every Parsec-sized packet used to cost a loopback write, a selector wakeup and a read plus a
 * thread handoff; here relay writes become AOA DATA frames directly.
 *
 * It mimics the loopback socket behaviour RelayServer relies on: soTimeout on reads, EOF after the
 * peer's FIN, shutdownOutput as FIN, and close() failing blocked reads/writes. Flow control is the
 * AOA credit window: writes wait for peer credit, and reads return credit as WINDOW frames.
 *
 * [send] must enqueue one encoded frame (blocking while the USB writer is backlogged) and is
 * called without holding [lock]. Bridge-side calls ([deliver], [remoteFinished], [credit],
 * [abort]) come from the selector thread; relay-side calls come from relay worker threads.
 */
internal class AoaPipeSocket(
    val streamId: Int,
    private val send: (ByteArray) -> Unit,
    private val onRelayClosed: (AoaPipeSocket) -> Unit,
) : Socket() {
    private val lock = Object()
    private val writeLock = Object() // keeps this stream's DATA/FIN in write order
    private val inbound = ArrayDeque<ByteArray>()
    private var headOffset = 0
    private var received = 0L
    private var consumed = 0L
    private var advertised = 0L
    private var sent = 0L
    private var peerConsumed = 0L
    private var remoteFin = false
    private var localFin = false
    private var closed = false
    private var aborted = false
    @Volatile private var readTimeoutMs = 0

    // Bridge side -----------------------------------------------------------------------------

    /** Returns false once the relay closed its side: the bridge then aborts like a closed socket. */
    fun deliver(payload: ByteArray): Boolean = synchronized(lock) {
        if (closed || aborted) return false
        if (remoteFin || received + payload.size - advertised > AoaFrame.INITIAL_CREDIT)
            throw IOException("DATA outside receive window")
        inbound.addLast(payload)
        received += payload.size
        lock.notifyAll()
        true
    }

    /** Peer FIN. Returns true when the relay already closed, so the stream is finished. */
    fun remoteFinished(): Boolean = synchronized(lock) {
        if (remoteFin) throw IOException("unexpected FIN")
        remoteFin = true
        lock.notifyAll()
        closed
    }

    fun credit(peerConsumedTotal: Long) = synchronized(lock) {
        if (peerConsumedTotal > sent) throw IOException("credit inflation")
        if (peerConsumedTotal > peerConsumed) { peerConsumed = peerConsumedTotal; lock.notifyAll() }
    }

    /** Peer CLOSE, session reset or USB loss: fail every blocked relay read and write. */
    fun abort() = synchronized(lock) { aborted = true; lock.notifyAll() }

    val isFinished: Boolean get() = synchronized(lock) { closed && remoteFin }
    val isAborted: Boolean get() = synchronized(lock) { aborted }

    // Relay side (Socket) ---------------------------------------------------------------------

    private val input = object : InputStream() {
        override fun read(): Int {
            val one = ByteArray(1)
            return if (read(one, 0, 1) < 0) -1 else one[0].toInt() and 255
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (off < 0 || len < 0 || len > b.size - off) throw IndexOutOfBoundsException()
            if (len == 0) return 0
            var window: Long? = null
            val count = synchronized(lock) {
                val timeout = readTimeoutMs
                val deadline = if (timeout > 0) System.nanoTime() + timeout * 1_000_000L else 0L
                while (inbound.isEmpty()) {
                    if (aborted || closed) throw IOException("Socket closed")
                    if (remoteFin) return -1
                    if (timeout == 0) lock.wait()
                    else {
                        val left = (deadline - System.nanoTime()) / 1_000_000
                        if (left <= 0) throw SocketTimeoutException("Read timed out")
                        lock.wait(left)
                    }
                }
                if (aborted || closed) throw IOException("Socket closed")
                var copied = 0
                while (copied < len && inbound.isNotEmpty()) {
                    val head = inbound.first
                    val n = minOf(len - copied, head.size - headOffset)
                    head.copyInto(b, off + copied, headOffset, headOffset + n)
                    copied += n
                    headOffset += n
                    if (headOffset == head.size) { inbound.removeFirst(); headOffset = 0 }
                }
                consumed += copied
                // Return credit once half a window is used. The sender then always keeps at least
                // half a window, so it never waits on credit for bytes already read; a WINDOW per
                // small read (Parsec input) cost a frame, a writer wakeup and a peer record each.
                if (consumed - advertised >= AoaFrame.INITIAL_CREDIT / 2) {
                    advertised = consumed
                    window = consumed
                }
                copied
            }
            window?.let { send(AoaFrame.window(streamId, it).encode()) }
            return count
        }

        override fun available(): Int = synchronized(lock) {
            inbound.sumOf { it.size } - headOffset
        }

        override fun close() = this@AoaPipeSocket.close()
    }

    private val output = object : OutputStream() {
        override fun write(b: Int) = write(byteArrayOf(b.toByte()), 0, 1)

        override fun write(b: ByteArray, off: Int, len: Int) {
            if (off < 0 || len < 0 || len > b.size - off) throw IndexOutOfBoundsException()
            synchronized(writeLock) {
                var pos = off
                while (pos < off + len) {
                    val chunk = synchronized(lock) {
                        while (true) {
                            if (aborted || closed) throw IOException("Socket closed")
                            if (localFin) throw IOException("Socket output is shutdown")
                            val credit = AoaFrame.INITIAL_CREDIT - (sent - peerConsumed)
                            if (credit > 0) break
                            lock.wait() // like a full socket send buffer: wait for peer WINDOW
                        }
                        val credit = (AoaFrame.INITIAL_CREDIT - (sent - peerConsumed)).toInt()
                        minOf(off + len - pos, credit, AoaFrame.SEND_PAYLOAD).also { sent += it }
                    }
                    send(AoaFrame.encodeData(streamId, b, pos, chunk))
                    pos += chunk
                }
            }
        }

        override fun close() = this@AoaPipeSocket.close()
    }

    override fun getInputStream(): InputStream = input
    override fun getOutputStream(): OutputStream = output
    override fun getInetAddress(): InetAddress = InetAddress.getLoopbackAddress()
    override fun setTcpNoDelay(on: Boolean) = Unit
    override fun setSoTimeout(timeout: Int) { require(timeout >= 0); readTimeoutMs = timeout }
    override fun getSoTimeout(): Int = readTimeoutMs
    override fun isClosed(): Boolean = synchronized(lock) { closed }
    override fun isConnected(): Boolean = true

    override fun shutdownOutput() = sendFin()

    /** Like closing the loopback socket: EOF (FIN) to the peer, then the bridge retires it. */
    override fun close() {
        synchronized(lock) {
            if (closed) return
            closed = true
            lock.notifyAll()
        }
        runCatching { sendFin() }
        onRelayClosed(this)
    }

    private fun sendFin() {
        synchronized(writeLock) {
            synchronized(lock) {
                if (localFin || aborted) return
                localFin = true
            }
            send(AoaFrame(AoaFrame.FIN, streamId).encode())
        }
    }
}
