package io.droidbridge.relay

import io.droidbridge.network.CellularUnavailableException
import io.droidbridge.policy.DestinationDeniedException
import io.droidbridge.protocol.DbpCodec
import io.droidbridge.protocol.DbpErrorCode
import io.droidbridge.protocol.DbpHeader
import io.droidbridge.protocol.DbpMessageType
import io.droidbridge.protocol.DbpPayload
import io.droidbridge.protocol.DbpProtocolException
import io.droidbridge.protocol.HealthStatus
import io.droidbridge.protocol.OpenDestination
import io.droidbridge.security.AuthenticatedSession
import io.droidbridge.security.DbpAuthenticationException
import io.droidbridge.security.SessionAuthenticator
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** What a relay session needs from the network layer; real impl wraps the cellular controller/DNS. */
interface RelayBackend {
    suspend fun connect(destination: OpenDestination): Socket
    suspend fun resolveDns(queryPacket: ByteArray): ByteArray
    fun carrierName(): String?
    fun cellularReady(): Boolean
}

/**
 * Loopback DBP/1 server. Binds 127.0.0.1 only, bounds total connections and TCP flows with separate
 * semaphores, authenticates each connection, then serves exactly one of OPEN_TCP / DNS_QUERY / HEALTH.
 */
class RelayServer(
    private val authenticator: SessionAuthenticator,
    private val backend: RelayBackend,
    private val maximumFlows: Int = 128,
    private val bridge: StreamBridge = StreamBridge(),
) {
    init { require(maximumFlows in 1..256) }

    val metrics = RelayMetrics(maximumFlows, backend::carrierName)

    private val connectionSlots = Semaphore(256) // caps unauthenticated sockets too
    private val flowSlots = Semaphore(maximumFlows)
    private val activeFlowSockets = ConcurrentHashMap.newKeySet<Socket>()
    private var serverSocket: ServerSocket? = null
    private var scope: CoroutineScope? = null

    val port: Int get() = serverSocket?.localPort ?: -1
    val boundAddress: InetAddress? get() = serverSocket?.inetAddress

    fun start(port: Int = DBP_PORT) {
        val socket = ServerSocket().apply {
            reuseAddress = false
            bind(InetSocketAddress(InetAddress.getLoopbackAddress(), port), 128)
        }
        serverSocket = socket
        val serverScope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        scope = serverScope
        serverScope.launch {
            while (true) {
                val client = try {
                    runInterruptible { socket.accept() }
                } catch (e: IOException) {
                    break // server closed
                }
                if (!client.inetAddress.isLoopbackAddress) { client.close(); continue }
                serverScope.launch { handleConnection(client) }
            }
        }
    }

    fun stop() {
        cancelActiveFlows()
        scope?.cancel()
        runCatching { serverSocket?.close() }
        serverSocket = null
        scope = null
    }

    /** Immediately tears down established bridges while leaving the authenticated listener available. */
    fun cancelActiveFlows() {
        activeFlowSockets.toList().forEach { socket -> runCatching { socket.close() } }
    }

    private suspend fun handleConnection(client: Socket) {
        if (!connectionSlots.tryAcquire()) { client.close(); return }
        try {
            client.tcpNoDelay = true
            val input = DataInputStream(client.getInputStream())
            val output = client.getOutputStream()
            val session = authenticateHello(input, output) ?: return
            serveRequest(client, input, output, session)
        } catch (e: DbpProtocolException) {
            // fail closed: silent
        } catch (e: DbpAuthenticationException) {
        } catch (e: IOException) {
        } catch (e: TimeoutCancellationException) {
        } finally {
            connectionSlots.release()
            runCatching { client.close() }
        }
    }

    private suspend fun authenticateHello(input: DataInputStream, output: OutputStream): AuthenticatedSession? {
        val (header, payload) = withTimeout(AUTH_TIMEOUT_MS) { readMessage(input) }
        val session = authenticator.acceptHello(header, payload) // throws on failure -> connection closed
        writeFrame(output, session.sign(DbpMessageType.HELLO_OK, ByteArray(0)))
        return session
    }

    private suspend fun serveRequest(client: Socket, input: DataInputStream, output: OutputStream, session: AuthenticatedSession) {
        val (header, payload) = withTimeout(AUTH_TIMEOUT_MS) { readMessage(input) }
        session.verifyFollowup(header, payload)
        when (header.type) {
            DbpMessageType.HEALTH -> {
                val status = if (backend.cellularReady()) HealthStatus.READY else HealthStatus.CELLULAR_UNAVAILABLE
                writeFrame(output, session.sign(DbpMessageType.HEALTH_RESPONSE, metrics.healthPayload(status)))
            }
            DbpMessageType.DNS_QUERY -> {
                val dns = payload.copyOfRange(2, payload.size)
                val response = try {
                    backend.resolveDns(dns)
                } catch (e: Exception) {
                    writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.DNS_FAILED)))
                    return
                }
                writeFrame(output, session.sign(DbpMessageType.DNS_RESPONSE, DbpCodec.encodeDns(response)))
            }
            DbpMessageType.OPEN_TCP -> openTcp(client, output, session, DbpCodec.decodeOpenTcp(payload))
            else -> throw DbpProtocolException("unexpected request ${header.type}")
        }
    }

    private suspend fun openTcp(client: Socket, output: OutputStream, session: AuthenticatedSession, destination: OpenDestination) {
        if (!backend.cellularReady()) {
            writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.CELLULAR_UNAVAILABLE)))
            return
        }
        if (!flowSlots.tryAcquire()) {
            writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.SESSION_LIMIT)))
            return
        }
        val remote = try {
            backend.connect(destination)
        } catch (e: DestinationDeniedException) {
            flowSlots.release()
            writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.POLICY_DENIED)))
            return
        } catch (e: CellularUnavailableException) {
            flowSlots.release()
            writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.CONNECT_REFUSED)))
            return
        } catch (e: IOException) {
            flowSlots.release()
            writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.CONNECT_TIMEOUT)))
            return
        }
        activeFlowSockets += client
        activeFlowSockets += remote
        var opened = false
        try {
            writeFrame(output, session.sign(DbpMessageType.OPEN_OK, ByteArray(0)))
            metrics.flowOpened()
            opened = true
            // after OPEN_OK the client socket is a raw byte stream
            val clientEnd = BridgeEnd("client", client.getInputStream(), output, { runCatching { client.shutdownOutput() } })
            val remoteEnd = BridgeEnd("remote", remote.getInputStream(), remote.getOutputStream(), { runCatching { remote.shutdownOutput() } })
            val (up, down) = bridge.copyBidirectional(clientEnd, remoteEnd)
            metrics.addTransfer(up, down)
        } finally {
            activeFlowSockets -= client
            activeFlowSockets -= remote
            if (opened) metrics.flowClosed()
            flowSlots.release()
            runCatching { remote.close() }
        }
    }

    /** Reads one framed control message: 64-byte header, then the type's exact payload. */
    private suspend fun readMessage(input: DataInputStream): Pair<DbpHeader, ByteArray> = withContext(Dispatchers.IO) {
        val headerBytes = ByteArray(DbpCodec.HEADER_SIZE)
        runInterruptible { input.readFully(headerBytes) }
        val header = DbpCodec.decodeHeader(headerBytes)
        val prefixLength = DbpCodec.payloadPrefixLength(header.type)
        val prefix = ByteArray(prefixLength).also { if (prefixLength > 0) runInterruptible { input.readFully(it) } }
        val remaining = DbpCodec.payloadRemaining(header.type, prefix)
        val rest = ByteArray(remaining).also { if (remaining > 0) runInterruptible { input.readFully(it) } }
        header to (prefix + rest)
    }

    private suspend fun writeFrame(output: OutputStream, frame: ByteArray) = withContext(Dispatchers.IO) {
        runInterruptible { output.write(frame); output.flush() }
    }

    companion object {
        const val DBP_PORT = 27183
        const val AUTH_TIMEOUT_MS = 3_000L
    }
}
