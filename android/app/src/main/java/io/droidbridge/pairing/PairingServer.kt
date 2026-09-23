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
import kotlinx.coroutines.withContext

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

    override suspend fun readFrame(): ByteArray = withContext(Dispatchers.IO) {
        val length = try { input.readInt() } catch (e: EOFException) { throw PairingException("peer closed") }
        if (length <= 0 || length > PairingFrames.MAX_FRAME) throw PairingException("frame size")
        ByteArray(length).also { input.readFully(it) }
    }

    override suspend fun writeFrame(frame: ByteArray) = withContext(Dispatchers.IO) {
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
    private var serverSocket: ServerSocket? = null

    val boundPort: Int get() = serverSocket?.localPort ?: -1
    val boundAddress: InetAddress? get() = serverSocket?.inetAddress

    fun open() {
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

    suspend fun acceptOne(): PairingChannel = withContext(Dispatchers.IO) {
        val server = serverSocket ?: throw PairingException("not open")
        val socket = server.accept()
        if (!socket.inetAddress.isLoopbackAddress) {
            socket.close()
            throw PairingException("non-loopback peer")
        }
        socket.soTimeout = READ_TIMEOUT_MS
        SocketPairingChannel(socket)
    }

    fun close() {
        try { serverSocket?.close() } catch (e: IOException) { /* ignore */ }
        serverSocket = null
    }

    companion object {
        const val DEFAULT_PORT = 27184
        private const val READ_TIMEOUT_MS = 65_000
    }
}
