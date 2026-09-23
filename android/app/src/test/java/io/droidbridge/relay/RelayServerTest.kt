package io.droidbridge.relay

import io.droidbridge.protocol.DbpCodec
import io.droidbridge.protocol.DbpErrorCode
import io.droidbridge.protocol.DbpHeader
import io.droidbridge.protocol.DbpHmac
import io.droidbridge.protocol.DbpMessageType
import io.droidbridge.protocol.DbpPayload
import io.droidbridge.protocol.HealthStatus
import io.droidbridge.protocol.OpenDestination
import io.droidbridge.network.CellularUnavailableException
import io.droidbridge.policy.DestinationDeniedException
import io.droidbridge.policy.PolicyResult
import io.droidbridge.security.EpochClock
import io.droidbridge.security.NonceReplayCache
import io.droidbridge.security.SessionAuthenticator
import java.io.DataInputStream
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds

private val SECRET = ByteArray(32).also { it[31] = 1 }

/** A raw duplex socket standing in for a cellular remote; records what it received and half-close. */
private class FakeDuplexSocket(response: ByteArray) : Socket() {
    private val toRemote = java.io.PipedOutputStream()
    private val remoteReads = java.io.PipedInputStream(toRemote, 1 shl 16)
    private val remoteWrites = java.io.ByteArrayOutputStream()
    val received get() = remoteWrites.toByteArray()
    var outputHalfClosed = false
    private val input = java.io.SequenceInputStream(java.io.ByteArrayInputStream(response), remoteReads)

    override fun getInputStream() = input
    override fun getOutputStream() = remoteWrites
    override fun shutdownOutput() { outputHalfClosed = true }
    override fun close() { runCatching { toRemote.close() }; super.close() }
}

private class FakeBackend(
    val remote: FakeDuplexSocket? = null,
    val cellular: Boolean = true,
    val carrier: String? = "MockCarrier",
    val dnsAnswer: ByteArray? = null,
) : RelayBackend {
    val connectCalls = AtomicInteger(0)
    override suspend fun connect(destination: OpenDestination): Socket {
        connectCalls.incrementAndGet()
        val addr = when (destination) {
            is OpenDestination.Ipv6 -> InetAddress.getByAddress(destination.address)
            is OpenDestination.Ipv4 -> InetAddress.getByAddress(destination.address)
            is OpenDestination.Domain -> InetAddress.getByName("93.184.216.34")
        }
        if (io.droidbridge.policy.DestinationPolicy.evaluate(addr) != PolicyResult.ALLOW) throw DestinationDeniedException(PolicyResult.DENY_PRIVATE)
        return remote ?: throw CellularUnavailableException()
    }
    override suspend fun resolveDns(queryPacket: ByteArray): ByteArray = dnsAnswer ?: throw io.droidbridge.network.DnsFailureException(io.droidbridge.network.DnsFailure.TIMEOUT)
    override fun carrierName(): String? = carrier
    override fun cellularReady(): Boolean = cellular
}

/** Real DBP/1 client over loopback for the end-to-end test. */
private class DbpTestClient(port: Int, private val secret: ByteArray = SECRET, private val nonce: Long = 0x51) : AutoCloseable {
    private val socket = Socket("127.0.0.1", port)
    private val input = DataInputStream(socket.getInputStream())
    private val output = socket.getOutputStream()
    private var serverNonce = 0L

    private fun frame(type: DbpMessageType, serverNonce: Long, payload: ByteArray): ByteArray {
        val header = DbpHeader(type, 0, nonce, serverNonce, 1_700_000_000, ByteArray(32))
        val mac = DbpHmac.compute(secret, header, payload)
        return DbpCodec.encodeHeader(header, mac) + payload
    }

    private fun read(): Pair<DbpHeader, ByteArray> {
        val h = ByteArray(64).also { input.readFully(it) }
        val header = DbpCodec.decodeHeader(h)
        val prefix = ByteArray(DbpCodec.payloadPrefixLength(header.type)).also { if (it.isNotEmpty()) input.readFully(it) }
        val remaining = DbpCodec.payloadRemaining(header.type, prefix)
        val rest = ByteArray(remaining).also { if (it.isNotEmpty()) input.readFully(it) }
        return header to (prefix + rest)
    }

    fun hello() {
        output.write(frame(DbpMessageType.HELLO, 0, ByteArray(0))); output.flush()
        val (header, _) = read()
        assertEquals(DbpMessageType.HELLO_OK, header.type)
        serverNonce = header.serverNonce
    }

    fun request(type: DbpMessageType, payload: ByteArray): Pair<DbpHeader, ByteArray> {
        output.write(frame(type, serverNonce, payload)); output.flush()
        return read()
    }

    fun writeRaw(bytes: ByteArray) { output.write(bytes); output.flush() }
    fun shutdownOutput() = socket.shutdownOutput()
    fun readAll(): ByteArray = input.readBytes()
    override fun close() { runCatching { socket.close() } }
}

class RelayServerTest {
    private lateinit var server: RelayServer

    private fun start(backend: RelayBackend, maxFlows: Int = 128): RelayServer {
        val auth = SessionAuthenticator({ SECRET }, NonceReplayCache(clock = FIXED), FIXED)
        server = RelayServer(auth, backend, maximumFlows = maxFlows, bridge = StreamBridge(idleMs = 1000, graceMs = 300))
        server.start(port = 0)
        return server
    }

    @AfterTest fun tearDown() { if (::server.isInitialized) server.stop() }

    @Test
    fun `binds loopback only`() {
        start(FakeBackend())
        assertTrue(server.boundAddress!!.isLoopbackAddress)
        assertEquals("127.0.0.1", server.boundAddress!!.hostAddress)
    }

    @Test
    fun `health returns ready with carrier and limits`() = clientTest(FakeBackend(cellular = true)) { client ->
        client.hello()
        val (header, payload) = client.request(DbpMessageType.HEALTH, ByteArray(0))
        assertEquals(DbpMessageType.HEALTH_RESPONSE, header.type)
        val health = DbpCodec.decodePayload(DbpMessageType.HEALTH_RESPONSE, payload) as DbpPayload.Health
        assertEquals(HealthStatus.READY, health.status)
        assertEquals(128, health.maximumSessions)
        assertEquals("MockCarrier", health.carrierName)
    }

    @Test
    fun `open tcp bridges bytes and applies half close`() {
        val remote = FakeDuplexSocket(response = "pong".toByteArray())
        val backend = FakeBackend(remote = remote)
        runBlocking {
            withTimeout(10.seconds) {
                start(backend)
                withContext(Dispatchers.IO) {
                    DbpTestClient(server.port).use { client ->
                        client.hello()
                        val (header, _) = client.request(DbpMessageType.OPEN_TCP, DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)))
                        assertEquals(DbpMessageType.OPEN_OK, header.type)
                        client.writeRaw("ping".toByteArray())
                        client.shutdownOutput()
                        assertContentEquals("pong".toByteArray(), client.readAll())
                    }
                }
            }
        }
        assertContentEquals("ping".toByteArray(), remote.received)
        assertTrue(remote.outputHalfClosed)
    }

    @Test
    fun `private destination is policy denied`() = clientTest(FakeBackend(remote = FakeDuplexSocket(ByteArray(0)))) { client ->
        client.hello()
        val (header, payload) = client.request(DbpMessageType.OPEN_TCP, DbpCodec.encodeOpenTcp(OpenDestination.Ipv4(byteArrayOf(10, 0, 0, 1), 443)))
        assertEquals(DbpMessageType.OPEN_ERROR, header.type)
        assertEquals(DbpErrorCode.POLICY_DENIED.code, payload[0].toInt())
    }

    @Test
    fun `cellular unavailable is rejected`() = clientTest(FakeBackend(cellular = false)) { client ->
        client.hello()
        val (header, payload) = client.request(DbpMessageType.OPEN_TCP, DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)))
        assertEquals(DbpMessageType.OPEN_ERROR, header.type)
        assertEquals(DbpErrorCode.CELLULAR_UNAVAILABLE.code, payload[0].toInt())
    }

    @Test
    fun `session limit returns SESSION_LIMIT`() {
        val backend = FakeBackend(remote = FakeDuplexSocket(ByteArray(0)))
        runBlocking {
            withTimeout(10.seconds) {
                start(backend, maxFlows = 1)
                withContext(Dispatchers.IO) {
                    val c1 = DbpTestClient(server.port, nonce = 1)
                    c1.hello()
                    val (h1, _) = c1.request(DbpMessageType.OPEN_TCP, DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)))
                    assertEquals(DbpMessageType.OPEN_OK, h1.type)
                    val c2 = DbpTestClient(server.port, nonce = 2)
                    c2.hello()
                    val (h2, p2) = c2.request(DbpMessageType.OPEN_TCP, DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)))
                    assertEquals(DbpMessageType.OPEN_ERROR, h2.type)
                    assertEquals(DbpErrorCode.SESSION_LIMIT.code, p2[0].toInt())
                    c1.close(); c2.close()
                }
            }
        }
    }

    @Test
    fun `completed flow releases its slot for the next connection`() {
        val backend = object : RelayBackend {
            override suspend fun connect(destination: OpenDestination): Socket = FakeDuplexSocket(ByteArray(0))
            override suspend fun resolveDns(queryPacket: ByteArray): ByteArray = error("unused")
            override fun carrierName(): String? = "MockCarrier"
            override fun cellularReady(): Boolean = true
        }
        runBlocking {
            withTimeout(10.seconds) {
                start(backend, maxFlows = 1)
                withContext(Dispatchers.IO) {
                    val first = DbpTestClient(server.port, nonce = 101)
                    first.hello()
                    val (opened, _) = first.request(
                        DbpMessageType.OPEN_TCP,
                        DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)),
                    )
                    assertEquals(DbpMessageType.OPEN_OK, opened.type)
                    server.metrics.snapshot.first { it.activeFlows == 1 }
                    first.close()
                    server.metrics.snapshot.first { it.activeFlows == 0 }

                    DbpTestClient(server.port, nonce = 102).use { second ->
                        second.hello()
                        val (reopened, _) = second.request(
                            DbpMessageType.OPEN_TCP,
                            DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)),
                        )
                        assertEquals(DbpMessageType.OPEN_OK, reopened.type)
                    }
                }
            }
        }
    }

    @Test
    fun `cancelling active flows closes their client sockets`() {
        val backend = object : RelayBackend {
            override suspend fun connect(destination: OpenDestination): Socket = FakeDuplexSocket(ByteArray(0))
            override suspend fun resolveDns(queryPacket: ByteArray): ByteArray = error("unused")
            override fun carrierName(): String? = "MockCarrier"
            override fun cellularReady(): Boolean = true
        }
        runBlocking {
            withTimeout(10.seconds) {
                start(backend, maxFlows = 1)
                withContext(Dispatchers.IO) {
                    val client = DbpTestClient(server.port, nonce = 103)
                    client.hello()
                    val (opened, _) = client.request(
                        DbpMessageType.OPEN_TCP,
                        DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)),
                    )
                    assertEquals(DbpMessageType.OPEN_OK, opened.type)
                    server.metrics.snapshot.first { it.activeFlows == 1 }

                    server.cancelActiveFlows()

                    assertContentEquals(ByteArray(0), client.readAll())
                    server.metrics.snapshot.first { it.activeFlows == 0 }
                    client.close()
                }
            }
        }
    }

    @Test
    fun `wrong secret is silently closed`() {
        start(FakeBackend())
        runBlocking {
            withTimeout(5.seconds) {
                withContext(Dispatchers.IO) {
                    DbpTestClient(server.port, secret = ByteArray(32)).use { client ->
                        val header = DbpHeader(DbpMessageType.HELLO, 0, 9, 0, 1_700_000_000, ByteArray(32))
                        val mac = DbpHmac.compute(ByteArray(32), header, ByteArray(0))
                        client.writeRaw(DbpCodec.encodeHeader(header, mac))
                        assertEquals(-1, DataInputStream(java.io.ByteArrayInputStream(client.readAll())).read())
                    }
                }
            }
        }
    }

    private fun clientTest(backend: RelayBackend, body: suspend (DbpTestClient) -> Unit) = runBlocking {
        withTimeout(10.seconds) {
            start(backend)
            withContext(Dispatchers.IO) {
                DbpTestClient(server.port).use { body(it) }
            }
        }
    }

    companion object {
        private val FIXED = EpochClock { 1_700_000_000 }
    }
}
