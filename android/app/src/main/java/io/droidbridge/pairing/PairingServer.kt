package io.droidbridge.pairing

import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.ensureActive

private val pairingIo = Dispatchers.IO.limitedParallelism(4)

/** Socket IO ignores thread interruption on some Android versions. Cancellation owns close. */
private suspend fun <T> cancellablePairingIo(close: () -> Unit, abandoned: (T) -> Unit = {}, block: () -> T): T =
    suspendCancellableCoroutine { continuation ->
        continuation.invokeOnCancellation { runCatching(close) }
        pairingIo.dispatch(continuation.context, Runnable {
            try {
                continuation.context.ensureActive()
                val value = block()
                continuation.resume(value) { _, result, _ -> abandoned(result) }
            } catch (error: Exception) { continuation.resumeWith(Result.failure(error)) }
        })
    }

/** One pairing conversation. Frames are raw JSON bytes; length framing is the channel's job. */
interface PairingChannel {
    suspend fun readFrame(): ByteArray
    suspend fun writeFrame(frame: ByteArray)
    fun close()
}

object PairingFrames {
    const val MAX_FRAME = 8192

    suspend fun readJson(channel: PairingChannel): String {
        val frame = channel.readFrame()
        if (frame.isEmpty() || frame.size > MAX_FRAME) throw PairingException("frame size")
        return String(frame, Charsets.UTF_8)
    }

    suspend fun writeJson(channel: PairingChannel, json: String) {
        val bytes = json.toByteArray(Charsets.UTF_8)
        if (bytes.size > MAX_FRAME) throw PairingException("frame size")
        channel.writeFrame(bytes)
    }
}

/** 4-byte big-endian length prefix, at most 8192 bytes of JSON, over a blocking socket. */
class SocketPairingChannel(private val socket: Socket) : PairingChannel {
    private val input = DataInputStream(socket.getInputStream())
    private val output = DataOutputStream(socket.getOutputStream())

    override suspend fun readFrame(): ByteArray = cancellablePairingIo(::close) {
        val length = try { input.readInt() } catch (e: EOFException) { throw PairingException("peer closed") }
        if (length <= 0 || length > PairingFrames.MAX_FRAME) throw PairingException("frame size")
        ByteArray(length).also { input.readFully(it) }
    }

    override suspend fun writeFrame(frame: ByteArray) = cancellablePairingIo(::close) {
        output.writeInt(frame.size)
        output.write(frame)
        output.flush()
    }

    override fun close() {
        try { socket.close() } catch (e: IOException) { /* already closed */ }
    }
}

/** Loopback-only pairing listener. Accepts exactly one connection per [acceptOne] call. */
class PairingServer(private val port: Int = DEFAULT_PORT) {
    @Volatile private var serverSocket: ServerSocket? = null

    val boundPort: Int get() = serverSocket?.localPort ?: -1
    val boundAddress: InetAddress? get() = serverSocket?.inetAddress

    @Synchronized fun open() {
        check(serverSocket == null) { "pairing server already open" }
        val socket = ServerSocket()
        try {
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 1)
            serverSocket = socket
        } catch (error: IOException) {
            try { socket.close() } catch (_: IOException) { /* bind already failed */ }
            throw error
        }
    }

    suspend fun acceptOne(): PairingChannel {
        val server = serverSocket ?: throw PairingException("not open")
        return cancellablePairingIo(close = { server.close() }, abandoned = { it.close() }) {
            val socket = server.accept()
            try {
                if (!socket.inetAddress.isLoopbackAddress) throw PairingException("non-loopback peer")
                socket.soTimeout = READ_TIMEOUT_MS
                SocketPairingChannel(socket)
            } catch (error: Exception) { socket.close(); throw error }
        }
    }

    @Synchronized fun close() {
        try { serverSocket?.close() } catch (e: IOException) { /* ignore */ }
        serverSocket = null
    }

    companion object {
        const val DEFAULT_PORT = 27184
        private const val READ_TIMEOUT_MS = 65_000
    }
}
