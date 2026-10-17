package io.droidbridge.relay

import io.droidbridge.network.CellularUnavailableException
import io.droidbridge.network.AddressFamilyUnavailableException
import io.droidbridge.network.SocketPolicyException
import io.droidbridge.protocol.*
import java.io.Closeable
import java.net.DatagramSocket
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
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
    suspend fun connectUdp(destination: OpenDestination): DatagramSocket = throw UnsupportedOperationException("UDP unavailable")
    suspend fun openUdpAssociation(family: Int): DatagramSocket = throw UnsupportedOperationException("UDP association unavailable")
    fun requireUdpDestination(address: InetAddress) = io.droidbridge.policy.DestinationPolicy.requireAllowed(address)
    suspend fun echo(request: IcmpRequest): IcmpReply = throw UnsupportedOperationException("ICMP unavailable")
    fun capabilities(): RelayCapabilities = RelayCapabilities(flags=if(cellularReady()) Capability.TCP4 else 0)
    fun release(socket: Closeable) {}
    fun trafficPolicy(): RelayTrafficPolicy = RelayTrafficPolicy()
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
    private val maximumUdpFlows: Int = 256,
    private val onUdpAssociationExit: (Int,UdpAssociationExitReason) -> Unit = { _,_ -> },
) {
    init { require(maximumFlows in 1..256); require(maximumUdpFlows in 1..256) }

    val metrics = RelayMetrics(maximumFlows, backend::carrierName)

    private val connectionSlots = Semaphore(576) // combined 512 data flows + 64 bounded control/auth connections
    private val pendingOpens = Semaphore(32)
    private val flowSlots = Semaphore(maximumFlows)
    private val udpSlots = Semaphore(maximumUdpFlows)
    private val epoch = AtomicLong()
    private val nextUdpId = AtomicInteger(1)
    private val allClients = ConcurrentHashMap.newKeySet<Socket>()
    private val activeFlowSockets = ConcurrentHashMap.newKeySet<Socket>()
    @Volatile private var serverSocket: ServerSocket? = null
    private var scope: CoroutineScope? = null

    val port: Int get() = serverSocket?.localPort ?: -1
    val boundAddress: InetAddress? get() = serverSocket?.inetAddress

    fun start(port: Int = DBP_PORT) {
        val socket = ServerSocket()
        try {
            // A completed relay connection can leave this local port in TIME_WAIT.
            // Permit an immediate Stop/Start without sharing a live listener's port.
            socket.reuseAddress = true
            // Android getLoopbackAddress() is ::1; DBAM's fixed service target is IPv4.
            socket.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), port), 128)
        } catch (error: Exception) {
            runCatching { socket.close() }
            throw error
        }
        serverSocket = socket
        val serverScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
        scope = serverScope
        serverScope.launch(RelayDispatchers.accepts) {
            while (true) {
                val client = try {
                    runInterruptible { socket.accept() }
                } catch (e: IOException) {
                    break // server closed
                }
                if (!client.inetAddress.isLoopbackAddress) { client.close(); continue }
                synchronized(this@RelayServer) {
                    if(serverSocket !== socket) { client.close() }
                    else { allClients += client; serverScope.launch { handleConnection(client) } }
                }
            }
        }
    }

    /** Serves an in-process connection (an AOA pipe) exactly like an accepted loopback socket. */
    fun accept(client: Socket): Boolean = synchronized(this) {
        val serverScope = scope
        if (serverSocket == null || serverScope == null) return false
        allClients += client
        serverScope.launch { handleConnection(client) }
        true
    }

    @Synchronized fun stop() {
        cancelActiveFlows()
        allClients.clear()
        scope?.cancel()
        runCatching { serverSocket?.close() }
        serverSocket = null
        scope = null
    }

    /** Immediately tears down established bridges while leaving the authenticated listener available. */
    fun cancelActiveFlows() {
        epoch.incrementAndGet()
        // Iterate the concurrent sets directly: toList() can observe size == 1 followed by an
        // empty iterator when a bridge finishes concurrently, throwing during disconnect.
        allClients.forEach { runCatching { it.close() } }
        activeFlowSockets.forEach { socket -> runCatching { socket.close() } }
    }

    private suspend fun handleConnection(client: Socket) {
        if (!connectionSlots.tryAcquire()) { allClients -= client; client.close(); return }
        try {
            client.tcpNoDelay = true
            client.soTimeout = AUTH_TIMEOUT_MS.toInt()
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
            allClients -= client
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
            DbpMessageType.CAPABILITIES -> {
                val caps=backend.capabilities().copy(activeUdp=metrics.activeUdp(),udpDrops=metrics.udpDrops())
                writeFrame(output,session.sign(DbpMessageType.CAPABILITIES_RESPONSE,ExtensionCodec.encodeCapabilities(caps)))
            }
            DbpMessageType.OPEN_UDP -> openUdp(client,output,session,ExtensionCodec.decodeUdpOpen(payload))
            DbpMessageType.OPEN_UDP_ASSOCIATION -> openUdpAssociation(client,output,session,ExtensionCodec.decodeUdpAssociationOpen(payload))
            DbpMessageType.ICMP_ECHO -> {
                val request=ExtensionCodec.decodeIcmpRequest(payload)
                try {
                    val response=backend.echo(request)
                    metrics.addTransfer(request.payload.size.toLong(),response.payload.size.toLong())
                    writeFrame(output,session.sign(DbpMessageType.ICMP_ECHO_RESPONSE,ExtensionCodec.encodeIcmpReply(response)))
                } catch(e: CancellationException) { throw e }
                catch(e: Exception) {
                    metrics.recordError(e)
                    writeFrame(output,session.sign(DbpMessageType.ICMP_ECHO_ERROR,ExtensionCodec.encodeIcmpError(request.requestId,errorCode(e))))
                }
            }
            DbpMessageType.HEALTH -> {
                val status = if (backend.cellularReady()) HealthStatus.READY else HealthStatus.CELLULAR_UNAVAILABLE
                writeFrame(output, session.sign(DbpMessageType.HEALTH_RESPONSE, metrics.healthPayload(status)))
            }
            DbpMessageType.DNS_QUERY -> {
                val dns = payload.copyOfRange(2, payload.size)
                val response = try {
                    backend.resolveDns(dns)
                } catch (e: CancellationException) { throw e } catch (e: Exception) {
                    metrics.recordError(e)
                    writeFrame(output, session.sign(DbpMessageType.OPEN_ERROR, DbpCodec.encodeError(DbpErrorCode.DNS_FAILED)))
                    return
                }
                metrics.addTransfer(dns.size.toLong(),response.size.toLong())
                backend.trafficPolicy().writeDownload(output, session.sign(DbpMessageType.DNS_RESPONSE, DbpCodec.encodeDns(response)))
            }
            DbpMessageType.OPEN_TCP -> openTcp(client, output, session, DbpCodec.decodeOpenTcp(payload))
            else -> throw DbpProtocolException("unexpected request ${header.type}")
        }
    }

    private fun errorCode(error: Exception): DbpErrorCode = when(error) {
        is DestinationDeniedException -> DbpErrorCode.POLICY_DENIED
        is AddressFamilyUnavailableException -> DbpErrorCode.ADDRESS_FAMILY_UNAVAILABLE
        is CellularUnavailableException -> DbpErrorCode.CELLULAR_UNAVAILABLE
        is UnsupportedOperationException -> DbpErrorCode.UDP_UNSUPPORTED
        is SocketPolicyException -> DbpErrorCode.POLICY_DENIED
        is java.net.SocketTimeoutException -> DbpErrorCode.CONNECT_TIMEOUT
        is IOException -> DbpErrorCode.CONNECT_REFUSED
        else -> DbpErrorCode.INTERNAL_ERROR
    }

    private suspend fun openTcp(client: Socket, output: OutputStream, session: AuthenticatedSession, destination: OpenDestination) {
        if(!backend.cellularReady()) { writeFrame(output,session.sign(DbpMessageType.OPEN_ERROR,DbpCodec.encodeError(DbpErrorCode.CELLULAR_UNAVAILABLE))); return }
        if(!flowSlots.tryAcquire()) { writeFrame(output,session.sign(DbpMessageType.OPEN_ERROR,DbpCodec.encodeError(DbpErrorCode.SESSION_LIMIT))); return }
        val startEpoch=epoch.get()
        var remote: Socket?=null
        var opened=false
        try {
            if (!pendingOpens.tryAcquire()) {
                writeFrame(output,session.sign(DbpMessageType.OPEN_ERROR,DbpCodec.encodeError(DbpErrorCode.SESSION_LIMIT)))
                return
            }
            val clientInput = try {
                watchPendingOpen(client) { remote = backend.connect(destination) }
            } catch(e: CancellationException) { throw e }
            catch(e: Exception) { metrics.recordError(e); writeFrame(output,session.sign(DbpMessageType.OPEN_ERROR,DbpCodec.encodeError(errorCode(e)))); return }
            finally { pendingOpens.release() }
            val connected = checkNotNull(remote)
            currentCoroutineContext().ensureActive()
            if(startEpoch!=epoch.get() || client.isClosed) return
            activeFlowSockets+=connected
            client.soTimeout=0
            writeFrame(output,session.sign(DbpMessageType.OPEN_OK,ByteArray(0)))
            metrics.flowOpened(); opened=true
            val a=BridgeEnd("client",clientInput,output,{ runCatching { client.shutdownOutput() } },{ client.close() })
            val b=BridgeEnd("remote",connected.getInputStream(),connected.getOutputStream(),{ runCatching { connected.shutdownOutput() } },{ connected.close() })
            bridge.copyBidirectional(a,b,backend.trafficPolicy(),metrics::addTransfer)
        } finally {
            remote?.let { activeFlowSockets-=it; runCatching { it.close() }; backend.release(it) }
            if(opened) metrics.flowClosed()
            flowSlots.release()
        }
    }

    /** A reset aborts the upstream attempt. EOF is a valid half-close and must retain replies.
     * Early bytes are bounded by the DBAM receive window and replayed without losing ordering. */
    private suspend fun watchPendingOpen(client: Socket, connect: suspend () -> Unit): InputStream =
        kotlinx.coroutines.coroutineScope {
            val owner = currentCoroutineContext()[Job]!!
            val done = java.util.concurrent.atomic.AtomicBoolean()
            val prefix = java.io.ByteArrayOutputStream()
            val input = client.getInputStream()
            client.soTimeout = 100
            val watcher = launch(RelayDispatchers.pendingReads) {
                val buffer = ByteArray(4096)
                try {
                    while (!done.get() && prefix.size() < 65536) {
                        val count = try { input.read(buffer, 0, minOf(buffer.size, 65536-prefix.size())) }
                        catch (_: java.net.SocketTimeoutException) { continue }
                        if (count < 0) break
                        prefix.write(buffer, 0, count)
                    }
                } catch (error: IOException) {
                    owner.cancel(CancellationException("pending client aborted", error))
                }
            }
            try { connect() }
            finally {
                done.set(true)
                kotlinx.coroutines.withContext(kotlinx.coroutines.NonCancellable) { watcher.join() }
            }
            val replay = java.io.ByteArrayInputStream(prefix.toByteArray())
            object : InputStream() {
                override fun read(): Int = if (replay.available() > 0) replay.read() else input.read()
                override fun read(b: ByteArray, off: Int, len: Int): Int =
                    if (replay.available() > 0) replay.read(b,off,len) else input.read(b,off,len)
                // EOF never closes the live socket: the opposite direction may still reply.
                override fun close() = input.close()
            }
        }

    private suspend fun openUdp(client: Socket,output: OutputStream,session: AuthenticatedSession,request: UdpOpen) {
        if(!backend.cellularReady()) { writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(DbpErrorCode.CELLULAR_UNAVAILABLE))); return }
        if(!udpSlots.tryAcquire()) { writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(DbpErrorCode.SESSION_LIMIT))); return }
        val startEpoch=epoch.get()
        var remote: DatagramSocket?=null
        var opened=false
        try {
            val connected=try { backend.connectUdp(request.destination) } catch(e: CancellationException) { throw e }
            catch(e: Exception) { metrics.recordError(e); writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(errorCode(e)))); return }
            remote=connected
            currentCoroutineContext().ensureActive()
            if(startEpoch!=epoch.get() || client.isClosed) return
            client.soTimeout=0
            writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_OK,ExtensionCodec.encodeUdpOk(nextUdpId.getAndIncrement(),request.idleSeconds)))
            metrics.udpOpened(); opened=true
            UdpRelaySession(client,connected,request.idleSeconds,backend.trafficPolicy(),metrics::addUdpDrops,metrics::addTransfer).run()
        } finally {
            remote?.let { it.close(); backend.release(it) }
            if(opened) metrics.udpClosed()
            udpSlots.release()
        }
    }

    private suspend fun openUdpAssociation(client: Socket,output: OutputStream,session: AuthenticatedSession,request: UdpAssociationOpen) {
        if(!backend.cellularReady()) { writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(DbpErrorCode.CELLULAR_UNAVAILABLE))); return }
        val flags=backend.capabilities().flags
        val familyFlag=if(request.family==4) Capability.UDP4 else Capability.UDP6
        if(flags and Capability.UDP_ASSOCIATION==0L || flags and familyFlag==0L) {
            val error=if(flags and Capability.UDP_ASSOCIATION==0L) DbpErrorCode.UDP_UNSUPPORTED else DbpErrorCode.ADDRESS_FAMILY_UNAVAILABLE
            writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(error))); return
        }
        if(!udpSlots.tryAcquire()) { writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(DbpErrorCode.SESSION_LIMIT))); return }
        val startEpoch=epoch.get()
        var remote: DatagramSocket?=null
        var opened=false
        try {
            val socket=try { backend.openUdpAssociation(request.family) } catch(e: CancellationException) { throw e }
            catch(e: Exception) { metrics.recordError(e); writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_ERROR,ExtensionCodec.encodeUdpError(errorCode(e)))); return }
            remote=socket
            currentCoroutineContext().ensureActive()
            if(startEpoch!=epoch.get() || client.isClosed) return
            client.soTimeout=0
            val associationId=nextUdpId.getAndIncrement()
            writeFrame(output,session.sign(DbpMessageType.OPEN_UDP_OK,ExtensionCodec.encodeUdpOk(associationId,request.idleSeconds)))
            metrics.udpOpened(); opened=true
            UdpAssociationRelaySession(client,socket,request,backend.trafficPolicy(),backend::requireUdpDestination,metrics::addUdpDrops,metrics::addTransfer,
                onExit={ reason -> onUdpAssociationExit(associationId,reason) }).run()
        } finally {
            remote?.let { it.close(); backend.release(it) }
            if(opened) metrics.udpClosed()
            udpSlots.release()
        }
    }

    /** Reads one framed control message: 64-byte header, then the type's exact payload. */
    private suspend fun readMessage(input: DataInputStream): Pair<DbpHeader, ByteArray> = withContext(RelayDispatchers.controlReads) {
        val headerBytes = ByteArray(DbpCodec.HEADER_SIZE)
        runInterruptible { input.readFully(headerBytes) }
        val header = DbpCodec.decodeHeader(headerBytes)
        val prefixLength = DbpCodec.payloadPrefixLength(header.type)
        val prefix = ByteArray(prefixLength).also { if (prefixLength > 0) runInterruptible { input.readFully(it) } }
        val remaining = DbpCodec.payloadRemaining(header.type, prefix)
        val rest = ByteArray(remaining).also { if (remaining > 0) runInterruptible { input.readFully(it) } }
        header to (prefix + rest)
    }

    private suspend fun writeFrame(output: OutputStream, frame: ByteArray) = withContext(RelayDispatchers.controlWrites) {
        runInterruptible { output.write(frame); output.flush() }
    }

    companion object {
        const val DBP_PORT = 27183
        const val AUTH_TIMEOUT_MS = 3_000L
    }
}
