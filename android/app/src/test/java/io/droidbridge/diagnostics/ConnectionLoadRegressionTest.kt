package io.droidbridge.diagnostics

import io.droidbridge.network.*
import io.droidbridge.protocol.OpenDestination
import io.droidbridge.protocol.*
import io.droidbridge.relay.*
import io.droidbridge.security.*
import io.droidbridge.usb.*
import java.io.BufferedInputStream
import java.io.OutputStream
import java.io.DataInputStream
import java.net.*
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.*
import kotlin.test.*

/** Regressions for bounded congestion and pending-open ownership. */
class ConnectionLoadRegressionTest {
    private val secret = ByteArray(32) { 1 }
    private val clock = object : EpochClock { override fun epochSeconds() = 1_700_000_000L }
    private inner class Client(port: Int, val nonce: Long) : AutoCloseable {
        val socket = Socket("127.0.0.1", port).apply { soTimeout = 3_000 }
        private val input = DataInputStream(socket.getInputStream())
        private var serverNonce = 0L
        fun send(type: DbpMessageType, payload: ByteArray = ByteArray(0)) {
            val h = DbpHeader(type,0,nonce,serverNonce,clock.epochSeconds(),ByteArray(32))
            socket.getOutputStream().write(DbpCodec.encodeHeader(h,DbpHmac.compute(secret,h,payload))+payload)
        }
        fun read(): Pair<DbpHeader, ByteArray> {
            val h = DbpCodec.decodeHeader(ByteArray(64).also(input::readFully))
            val prefix = ByteArray(DbpCodec.payloadPrefixLength(h.type)).also(input::readFully)
            val rest = ByteArray(DbpCodec.payloadRemaining(h.type,prefix)).also(input::readFully)
            return h to (prefix + rest)
        }
        fun hello() { send(DbpMessageType.HELLO); val h=read().first; assertEquals(DbpMessageType.HELLO_OK,h.type); serverNonce=h.serverNonce }
        override fun close() = socket.close()
    }

    @Test fun earlyPayloadAndHalfCloseSurvivePendingOpen() {
        ServerSocket(0).use { upstream ->
            val received = AtomicReference<ByteArray>()
            val responder = kotlin.concurrent.thread(isDaemon=true) {
                upstream.accept().use { peer ->
                    received.set(peer.getInputStream().readBytes())
                    peer.getOutputStream().write("reply-after-fin".toByteArray())
                }
            }
            val backend = object : RelayBackend {
                override suspend fun connect(destination: OpenDestination): Socket {
                    delay(250)
                    return Socket("127.0.0.1", upstream.localPort)
                }
                override suspend fun resolveDns(queryPacket: ByteArray) = ByteArray(0)
                override fun carrierName() = "Test"
                override fun cellularReady() = true
            }
            val relay = RelayServer(SessionAuthenticator({secret},NonceReplayCache(clock=clock),clock),backend)
            try {
                relay.start(0)
                Client(relay.port,100).use { client ->
                    client.hello()
                    client.send(DbpMessageType.OPEN_TCP,DbpCodec.encodeOpenTcp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443)))
                    client.socket.getOutputStream().write("early-request".toByteArray())
                    client.socket.shutdownOutput()
                    assertEquals(DbpMessageType.OPEN_OK,client.read().first.type)
                    assertContentEquals("reply-after-fin".toByteArray(),client.socket.getInputStream().readBytes())
                }
                responder.join(2000)
                assertContentEquals("early-request".toByteArray(),received.get())
            } finally { relay.stop() }
        }
    }

    @Test fun temporaryUsbOutputBackpressureDoesNotTearDownAllStreams() {
        val released = CountDownLatch(1)
        val blocked = CountDownLatch(1)
        val closed = AtomicReference<String?>()
        val peers = ArrayList<Socket>()
        ServerSocket(0).use { usb -> Socket("127.0.0.1", usb.localPort).use { host ->
            host.soTimeout = 5_000
            host.tcpNoDelay = true
            val accessory = usb.accept().apply { tcpNoDelay = true }
            val target = accessory.getOutputStream()
            val gate = object : OutputStream() {
                @Volatile var paused = false
                override fun write(value: Int) { write(byteArrayOf(value.toByte())) }
                override fun write(bytes: ByteArray, off: Int, len: Int) {
                    if (paused) { blocked.countDown(); check(released.await(5, TimeUnit.SECONDS)) }
                    target.write(bytes, off, len)
                }
            }
            ServerSocket(0).use { relay ->
                relay.soTimeout = 5_000
                val bridge = AoaAccessoryBridge(accessory.getInputStream(), gate,
                    relay.localPort, relay.localPort,
                    closeTransport = { released.countDown(); accessory.close() },
                    onClosed = { closed.compareAndSet(null, it) })
                bridge.start()
                try {
                    val input = BufferedInputStream(host.getInputStream())
                    fun send(frame: AoaFrame) { host.getOutputStream().write(frame.encode()) }
                    send(AoaFrame(AoaFrame.RESET, 0, payload = ByteArray(16)))
                    assertEquals(AoaFrame.RESET_OK, AoaFrame.read(input)!!.type)
                    repeat(64) { index ->
                        send(AoaFrame(AoaFrame.OPEN, index * 2 + 1, AoaFrame.RELAY))
                        peers += relay.accept().apply { tcpNoDelay = true }
                        assertEquals(AoaFrame.OPEN_OK, AoaFrame.read(input)!!.type)
                    }
                    gate.paused = true
                    val payload = ByteArray(512) { 7 }
                    val start = System.nanoTime()
                    peers.first().getOutputStream().write(payload)
                    assertTrue(blocked.await(2, TimeUnit.SECONDS), "USB sink was not paused")
                    var submitted = payload.size
                    for (round in 0 until 40) {
                        if (closed.get() != null) break
                        peers.forEach { peer ->
                            try { peer.getOutputStream().write(payload); submitted += payload.size }
                            catch (_: java.io.IOException) { /* capture the bridge's original failure */ }
                        }
                        Thread.sleep(10)
                    }
                    Thread.sleep(100)
                    val elapsed = (System.nanoTime() - start) / 1_000_000
                    println("streams=64 bytesSubmitted=$submitted perStreamBudget=${AoaFrame.INITIAL_CREDIT} pauseMs=$elapsed closeReason=${closed.get()}")
                    assertNull(closed.get(), "Valid data within stream credit must backpressure, not close the USB session")
                    released.countDown()
                    peers.forEach { it.shutdownOutput() }
                    val counts = IntArray(64)
                    var fins = 0
                    while (fins < 64) {
                        val frame = AoaFrame.read(input)!!
                        val i = (frame.streamId - 1) / 2
                        when (frame.type) {
                            AoaFrame.DATA -> { assertTrue(frame.payload.all { it == 7.toByte() }); counts[i] += frame.payload.size }
                            AoaFrame.FIN -> { assertEquals(40 * 512 + if(i == 0) 512 else 0, counts[i]); fins++ }
                            else -> fail("Unexpected frame ${frame.type}")
                        }
                    }
                    assertEquals(submitted, counts.sum())
                } finally {
                    released.countDown()
                    peers.forEach { runCatching { it.close() } }
                    bridge.close()
                }
            }
        } }
    }

    @Test fun cancelledConnectDoesNotKeepSocketOrTryMoreAddresses() = runBlocking {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val attempts = AtomicInteger()
        val firstSocket = AtomicReference<Socket>()
        val network = object : NetworkHandle {}
        val facade = object : ConnectivityFacade {
            override fun requestCellular(callback: CellularCallback) = callback.onAvailable(network, "Test")
            override fun unregister(callback: CellularCallback) {}
            override fun dnsServers(network: NetworkHandle) = emptyList<InetAddress>()
            override fun resolve(network: NetworkHandle, domain: String) = listOf(
                InetAddress.getByAddress(byteArrayOf(8,8,8,8)),
                InetAddress.getByAddress(byteArrayOf(1,1,1,1)),
                InetAddress.getByAddress(byteArrayOf(9,9,9,9)))
            override fun createSocket(network: NetworkHandle): Socket = object : Socket() {
                override fun connect(endpoint: SocketAddress?, timeout: Int) {
                    if (attempts.incrementAndGet() == 1) {
                        firstSocket.set(this)
                        entered.countDown()
                        release.await(5, TimeUnit.SECONDS)
                    }
                    throw SocketTimeoutException("controlled connect timeout")
                }
            }
        }
        val controller = CellularNetworkController(facade).apply { start() }
        val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
        val job = scope.launch { runCatching { controller.connectTcp(OpenDestination.Domain("example.test",443)) } }
        try {
            assertTrue(entered.await(2, TimeUnit.SECONDS))
            job.cancel()
            delay(200)
            val retainedAfterCancel = !firstSocket.get().isClosed
            val completedAfterCancel = job.isCompleted
            release.countDown()
            withTimeout(2_000) { job.join() }
            println("cancelled=true retainedAfter200ms=$retainedAfterCancel completedAfter200ms=$completedAfterCancel totalAddressAttempts=${attempts.get()}")
            assertEquals(1, attempts.get(), "Cancelled operation still tries all remaining DNS addresses")
            assertFalse(retainedAfterCancel, "Cancelled connect retains its socket and IO worker")
        } finally {
            release.countDown()
            controller.stop()
            scope.cancel()
        }
    }

    @Test fun disconnectedPendingRequestsReleaseFlowSlotsForNewClients() {
        val entered = CountDownLatch(2)
        val release = CountDownLatch(1)
        val net = object : NetworkHandle {}
        val facade = object : ConnectivityFacade {
            override fun requestCellular(callback: CellularCallback) = callback.onAvailable(net,"Test")
            override fun unregister(callback: CellularCallback) {}
            override fun dnsServers(network: NetworkHandle) = emptyList<InetAddress>()
            override fun resolve(network: NetworkHandle,domain: String) = emptyList<InetAddress>()
            override fun createSocket(network: NetworkHandle): Socket = object : Socket() {
                override fun connect(endpoint: SocketAddress?, timeout: Int) {
                    if ((endpoint as InetSocketAddress).address.address[0] == 8.toByte()) {
                        entered.countDown()
                        release.await(5,TimeUnit.SECONDS)
                        throw SocketTimeoutException("controlled timeout")
                    }
                }
                override fun getInputStream() = java.io.ByteArrayInputStream(ByteArray(0))
                override fun getOutputStream() = java.io.ByteArrayOutputStream()
                override fun shutdownOutput() {}
            }
        }
        val controller=CellularNetworkController(facade).apply { start() }
        val backend=object : RelayBackend {
            override suspend fun connect(destination: OpenDestination)=controller.connectTcp(destination)
            override suspend fun resolveDns(queryPacket: ByteArray)=ByteArray(0)
            override fun carrierName()="Test"
            override fun cellularReady()=true
            override fun release(socket: java.io.Closeable)=controller.release(socket)
        }
        val server=RelayServer(SessionAuthenticator({secret},NonceReplayCache(clock=clock),clock),backend,maximumFlows=2)
        try {
            server.start(0)
            fun freshOpen(nonce: Long): Pair<DbpHeader, ByteArray> = Client(server.port,nonce).use { client ->
                client.hello()
                client.send(DbpMessageType.OPEN_TCP,DbpCodec.encodeOpenTcp(OpenDestination.Ipv4(byteArrayOf(9,9,9,9),443)))
                client.read()
            }
            assertEquals(DbpMessageType.OPEN_OK,freshOpen(10).first.type)
            val baselineDeadline=System.nanoTime()+2_000_000_000L
            while(server.metrics.snapshot.value.activeFlows>0 && System.nanoTime()<baselineDeadline) Thread.sleep(5)
            val pending=(0..1).map { index -> Client(server.port,index+20L).apply {
                hello(); send(DbpMessageType.OPEN_TCP,DbpCodec.encodeOpenTcp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443)))
            } }
            assertTrue(entered.await(2,TimeUnit.SECONDS))
            // Abortive close is a reset, not a valid TCP half-close awaiting a response.
            pending.forEach { it.socket.setSoLinger(true,0); it.close() }
            Thread.sleep(200)
            val response=freshOpen(30)
            println("closedClients=2 flowLimit=2 establishedMetric=${server.metrics.snapshot.value.activeFlows} freshResponse=${response.first.type} errorCode=${response.second.firstOrNull()}")
            release.countDown()
            var nonce=31L
            val recoveryDeadline=System.nanoTime()+2_000_000_000L
            var recovered=freshOpen(nonce++)
            while(recovered.first.type!=DbpMessageType.OPEN_OK && System.nanoTime()<recoveryDeadline) {
                Thread.sleep(10); recovered=freshOpen(nonce++)
            }
            println("afterSlowConnectsReleased=${recovered.first.type}")
            assertEquals(DbpMessageType.OPEN_OK,recovered.first.type,"control: release of pending opens restores capacity")
            assertEquals(DbpMessageType.OPEN_OK,response.first.type,
                "All former clients disconnected but their slow opens still exhaust the connection limit")
        } finally {
            release.countDown()
            server.stop()
            controller.stop()
        }
    }
}
