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
import kotlin.test.assertFailsWith
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
private class DbpTestClient(private val socket: Socket, private val secret: ByteArray = SECRET, private val nonce: Long = 0x51) : AutoCloseable {
    constructor(port: Int, secret: ByteArray = SECRET, nonce: Long = 0x51) : this(Socket("127.0.0.1", port), secret, nonce)
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
        server = RelayServer(auth, backend, maximumFlows = maxFlows, bridge = StreamBridge(idleMs = 1000))
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
    fun `restart immediately reuses its port after a completed health connection`() {
        start(FakeBackend())
        val port = server.port
        DbpTestClient(port).use { client ->
            client.hello()
            assertEquals(DbpMessageType.HEALTH_RESPONSE,
                client.request(DbpMessageType.HEALTH, ByteArray(0)).first.type)
            // Observe the server's FIN before closing the peer: its local port enters TIME_WAIT.
            assertTrue(client.readAll().isEmpty())
        }
        server.stop()
        server.start(port)
        DbpTestClient(port, nonce = 0x52).use { client ->
            client.hello()
            assertEquals(DbpMessageType.HEALTH_RESPONSE,
                client.request(DbpMessageType.HEALTH, ByteArray(0)).first.type)
        }
    }

    @Test
    fun `another live listener cannot take the relay port`() {
        start(FakeBackend())
        val other = RelayServer(SessionAuthenticator({ SECRET }, NonceReplayCache(clock = FIXED), FIXED), FakeBackend())
        try {
            assertFailsWith<java.net.BindException> { other.start(server.port) }
            DbpTestClient(server.port).use { client ->
                client.hello()
                assertEquals(DbpMessageType.HEALTH_RESPONSE,
                    client.request(DbpMessageType.HEALTH, ByteArray(0)).first.type)
            }
        } finally { other.stop() }
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
    fun `flow completion can race with cancellation without breaking disconnect`() = runBlocking {
        val backend = object : RelayBackend {
            override suspend fun connect(destination: OpenDestination): Socket = FakeDuplexSocket(ByteArray(0))
            override suspend fun resolveDns(queryPacket: ByteArray): ByteArray = error("unused")
            override fun carrierName(): String? = "MockCarrier"
            override fun cellularReady(): Boolean = true
        }
        withTimeout(10.seconds) {
            start(backend, maxFlows = 1)
            withContext(Dispatchers.IO) {
                repeat(100) { index ->
                    DbpTestClient(server.port, nonce = 1000L + index).use { client ->
                        client.hello()
                        val (opened, _) = client.request(
                            DbpMessageType.OPEN_TCP,
                            DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)),
                        )
                        assertEquals(DbpMessageType.OPEN_OK, opened.type)
                        server.metrics.snapshot.first { it.activeFlows == 1 }
                        client.close()
                        // The completed bridge removes sockets while disconnect iterates them.
                        server.cancelActiveFlows()
                        server.metrics.snapshot.first { it.activeFlows == 0 }
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

/** USB accessory relay streams reach RelayServer in memory (no loopback hop) and behave the same. */
class AoaInMemoryRelayTest {
    private val clock = EpochClock { 1_700_000_000 }

    private fun dbp(type: DbpMessageType, serverNonce: Long, payload: ByteArray = ByteArray(0)): ByteArray {
        val header = DbpHeader(type, 0, 0x61, serverNonce, 1_700_000_000, ByteArray(32))
        return DbpCodec.encodeHeader(header, DbpHmac.compute(SECRET, header, payload)) + payload
    }

    @Test fun `HELLO and HEALTH run over an in-memory AOA stream and both sides finish`() {
        val server = RelayServer(SessionAuthenticator({ SECRET }, NonceReplayCache(clock = clock), clock), FakeBackend(),
            bridge = StreamBridge(idleMs = 1000))
        server.start(port = 0)
        java.net.ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            val accessory = usb.accept()
            val bridge = io.droidbridge.usb.AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                closeTransport = { accessory.close() }, relayAcceptor = server::accept)
            bridge.start()
            val input = java.io.BufferedInputStream(host.getInputStream())
            fun send(frame: io.droidbridge.usb.AoaFrame) = host.getOutputStream().write(frame.encode())
            fun next() = io.droidbridge.usb.AoaFrame.read(input)!!
            val received = java.io.ByteArrayOutputStream()
            fun dbpReply(): DbpHeader {
                while (received.size() < 64) {
                    val frame = next()
                    if (frame.type == io.droidbridge.usb.AoaFrame.DATA) received.write(frame.payload)
                }
                val bytes = received.toByteArray()
                val header = DbpCodec.decodeHeader(bytes.copyOf(64))
                received.reset(); received.write(bytes, 64, bytes.size - 64)
                return header
            }
            try {
                send(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.RESET, 0, payload = ByteArray(16)))
                assertEquals(io.droidbridge.usb.AoaFrame.RESET_OK, next().type)
                send(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.OPEN, 1, io.droidbridge.usb.AoaFrame.RELAY))
                assertEquals(io.droidbridge.usb.AoaFrame.OPEN_OK, next().type)
                send(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.DATA, 1, payload = dbp(DbpMessageType.HELLO, 0)))
                val hello = dbpReply()
                assertEquals(DbpMessageType.HELLO_OK, hello.type)
                send(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.DATA, 1, payload = dbp(DbpMessageType.HEALTH, hello.serverNonce)))
                assertEquals(DbpMessageType.HEALTH_RESPONSE, dbpReply().type)
                // The relay closes after one request: its FIN arrives, then ours finishes the stream.
                var sawFin = false
                while (!sawFin) sawFin = next().type == io.droidbridge.usb.AoaFrame.FIN
                send(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.FIN, 1))
                send(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.PING, 0))
                var pong = false
                while (!pong) pong = next().type == io.droidbridge.usb.AoaFrame.PONG
            } finally { bridge.close(); server.stop() }
        } }
    }

    @Test fun `a stopped relay refuses the stream with CLOSE`() {
        val server = RelayServer(SessionAuthenticator({ SECRET }, NonceReplayCache(clock = clock), clock), FakeBackend())
        java.net.ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5000
            val accessory = usb.accept()
            val bridge = io.droidbridge.usb.AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                closeTransport = { accessory.close() }, relayAcceptor = server::accept)
            bridge.start()
            val input = java.io.BufferedInputStream(host.getInputStream())
            try {
                host.getOutputStream().write(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.RESET, 0, payload = ByteArray(16)).encode())
                assertEquals(io.droidbridge.usb.AoaFrame.RESET_OK, io.droidbridge.usb.AoaFrame.read(input)!!.type)
                host.getOutputStream().write(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.OPEN, 1, io.droidbridge.usb.AoaFrame.RELAY).encode())
                assertEquals(io.droidbridge.usb.AoaFrame.CLOSE, io.droidbridge.usb.AoaFrame.read(input)!!.type)
            } finally { bridge.close() }
        } }
    }

    /** The Mac end of AOA stream 1, built from the production pipe over the raw AOA wire. */
    private fun macStream(host: Socket): Socket {
        val out = host.getOutputStream()
        val mac = io.droidbridge.usb.AoaPipeSocket(1, { synchronized(out) { out.write(it) } }) {}
        val opened = java.util.concurrent.CountDownLatch(1)
        val ready = java.util.concurrent.CountDownLatch(1)
        val input = java.io.BufferedInputStream(host.getInputStream())
        Thread {
            runCatching {
                while (true) {
                    val f = io.droidbridge.usb.AoaFrame.read(input) ?: break
                    when (f.type) {
                        io.droidbridge.usb.AoaFrame.RESET_OK -> ready.countDown()
                        io.droidbridge.usb.AoaFrame.OPEN_OK -> opened.countDown()
                        io.droidbridge.usb.AoaFrame.DATA -> mac.deliver(f.payload)
                        io.droidbridge.usb.AoaFrame.WINDOW -> mac.credit(f.credit())
                        io.droidbridge.usb.AoaFrame.FIN -> mac.remoteFinished()
                        io.droidbridge.usb.AoaFrame.CLOSE -> mac.abort()
                    }
                }
            }
        }.apply { isDaemon = true; start() }
        // Like the Mac mux: no stream opens before the RESET_OK barrier.
        synchronized(out) { out.write(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.RESET, 0, payload = ByteArray(16)).encode()) }
        assertTrue(ready.await(2, java.util.concurrent.TimeUnit.SECONDS))
        synchronized(out) { out.write(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.OPEN, 1, io.droidbridge.usb.AoaFrame.RELAY).encode()) }
        assertTrue(opened.await(2, java.util.concurrent.TimeUnit.SECONDS))
        return mac.apply { soTimeout = 5000 }
    }

    @Test fun `TCP over an in-memory AOA stream moves 256 KiB each way and propagates half close`() {
        java.net.ServerSocket(0).use { echo ->
            Thread { echo.accept().use { s -> s.getInputStream().copyTo(s.getOutputStream()); s.shutdownOutput() } }
                .apply { isDaemon = true; start() }
            val backend = object : RelayBackend {
                override suspend fun connect(destination: OpenDestination): Socket = Socket("127.0.0.1", echo.localPort)
                override suspend fun resolveDns(queryPacket: ByteArray): ByteArray = error("unexpected DNS")
                override fun carrierName(): String? = "test"
                override fun cellularReady(): Boolean = true
            }
            val server = RelayServer(SessionAuthenticator({ SECRET }, NonceReplayCache(clock = clock), clock), backend)
            server.start(port = 0)
            java.net.ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
                val accessory = usb.accept()
                val bridge = io.droidbridge.usb.AoaAccessoryBridge(accessory.getInputStream(), accessory.getOutputStream(),
                    closeTransport = { accessory.close() }, relayAcceptor = server::accept)
                bridge.start()
                try {
                    DbpTestClient(macStream(host), nonce = 0x62).use { client ->
                        client.hello()
                        val (header, _) = client.request(DbpMessageType.OPEN_TCP, DbpCodec.encodeOpenTcp(OpenDestination.Domain("example.com", 443)))
                        assertEquals(DbpMessageType.OPEN_OK, header.type)
                        val body = ByteArray(256 * 1024) { (it * 31).toByte() }
                        val reader = java.util.concurrent.Executors.newSingleThreadExecutor().submit<ByteArray> { client.readAll() }
                        client.writeRaw(body)
                        client.shutdownOutput()
                        assertContentEquals(body, reader.get(10, java.util.concurrent.TimeUnit.SECONDS),
                            "every byte returns and the echo's FIN ends the stream")
                    }
                } finally { bridge.close(); server.stop() }
            } }
        }
    }
}
