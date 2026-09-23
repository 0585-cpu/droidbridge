package io.droidbridge.relay

import io.droidbridge.protocol.*
import io.droidbridge.security.*
import io.droidbridge.network.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.net.*
import java.io.*
import java.util.concurrent.atomic.AtomicLong

class RelayExtensionsTest {
    private val secret=ByteArray(32) { 7 }
    private val clock=EpochClock { 1700000000 }
    private val nonce=AtomicLong(100)
    private inner class Client(port: Int) : AutoCloseable {
        val socket=Socket("127.0.0.1",port).apply { soTimeout=2000 }
        val input=DataInputStream(socket.getInputStream())
        val output=socket.getOutputStream()
        val clientNonce=nonce.incrementAndGet()
        var serverNonce=0L
        fun send(type: DbpMessageType,payload: ByteArray=byteArrayOf()) {
            val h=DbpHeader(type,0,clientNonce,serverNonce,clock.epochSeconds(),ByteArray(32))
            output.write(DbpCodec.encodeHeader(h,DbpHmac.compute(secret,h,payload))+payload)
        }
        fun read(): Pair<DbpMessageType,ByteArray> {
            val h=DbpCodec.decodeHeader(ByteArray(64).also(input::readFully))
            val prefix=ByteArray(DbpCodec.payloadPrefixLength(h.type)).also(input::readFully)
            val payload=prefix+ByteArray(DbpCodec.payloadRemaining(h.type,prefix)).also(input::readFully)
            assertArrayEquals(h.hmac,DbpHmac.compute(secret,h.copy(hmac=ByteArray(32)),payload))
            serverNonce=h.serverNonce
            return h.type to payload
        }
        fun hello() { send(DbpMessageType.HELLO); assertEquals(DbpMessageType.HELLO_OK,read().first) }
        override fun close()=socket.close()
    }
    private open class Backend : RelayBackend {
        override suspend fun connect(destination: OpenDestination): Socket=error("unexpected TCP")
        override suspend fun resolveDns(queryPacket: ByteArray): ByteArray=error("unexpected DNS")
        override fun cellularReady()=true
        override fun carrierName()="test"
        override fun capabilities()=RelayCapabilities(flags=Capability.TCP4 or Capability.UDP4 or Capability.PROFILES,generation=8)
    }
    private fun server(backend: RelayBackend)=RelayServer(SessionAuthenticator({secret},NonceReplayCache(clock=clock),clock),backend).apply { start(0) }
    @Test fun `capabilities require authentication and have signed exact versioned layout`() {
        val server=server(Backend())
        try {
            Client(server.port).use { it.send(DbpMessageType.CAPABILITIES); assertEquals(-1,it.input.read()) }
            Client(server.port).use {
                it.hello(); it.send(DbpMessageType.CAPABILITIES)
                val (type,bytes)=it.read(); assertEquals(DbpMessageType.CAPABILITIES_RESPONSE,type)
                assertEquals(61,bytes.size); assertEquals(8,ExtensionCodec.decodeCapabilities(bytes).generation)
            }
        } finally { server.stop() }
    }
    @Test fun `authenticated UDP uses injected cellular sockets and first queued raw frame survives open`() = runBlocking {
        DatagramSocket(0,InetAddress.getLoopbackAddress()).use { echo ->
            echo.soTimeout=2000
            val net=object: NetworkHandle {}
            val facade=object: ConnectivityFacade {
                override fun requestCellular(callback: CellularCallback) { callback.onAvailable(net,"test") }
                override fun unregister(callback: CellularCallback) {}
                override fun resolve(network: NetworkHandle,domain: String)=emptyList<InetAddress>()
                override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
                override fun createSocket(network: NetworkHandle)=Socket()
                override fun createDatagramSocket(network: NetworkHandle): DatagramSocket {
                    assertSame(net,network)
                    return object: DatagramSocket(null as SocketAddress?) {
                        override fun connect(address: SocketAddress?) { super.connect(echo.localSocketAddress) }
                    }
                }
            }
            val controller=CellularNetworkController(facade).apply { start() }
            val backend=object: Backend() {
                override suspend fun connectUdp(destination: OpenDestination)=controller.connectUdp(destination)
                override fun release(socket: Closeable)=controller.release(socket)
            }
            val server=server(backend); controller.addLossListener(server::cancelActiveFlows)
            try {
                Client(server.port).use {
                    it.hello(); it.send(DbpMessageType.OPEN_UDP,ExtensionCodec.encodeUdpOpen(UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443))))
                    it.output.write(DatagramCodec.encode(RawDatagram(byteArrayOf(1,2,3),0,0)))
                    assertEquals(DbpMessageType.OPEN_UDP_OK,it.read().first)
                    val packet=DatagramPacket(ByteArray(10),10)
                    withContext(Dispatchers.IO) { echo.receive(packet) }
                    assertArrayEquals(byteArrayOf(1,2,3),packet.data.copyOf(packet.length))
                    echo.send(DatagramPacket(packet.data,packet.length,packet.socketAddress))
                    assertArrayEquals(byteArrayOf(1,2,3),DatagramCodec.read(it.input,1)!!.payload)
                    controller.onLost(net)
                    assertEquals(-1,it.input.read())
                }
            } finally { server.stop(); controller.stop() }
        }
    }
    @Test fun `stop closes sockets still authenticating`() {
        val server=server(Backend())
        Client(server.port).use { client ->
            client.hello(); server.stop(); assertEquals(-1,client.input.read())
        }
    }
    @Test fun `UDP capacity is bounded and slot returns after EOF`() = runBlocking {
        val backend=object: Backend() {
            override suspend fun connectUdp(destination: OpenDestination)=DatagramSocket().apply { connect(InetAddress.getLoopbackAddress(),9) }
        }
        val server=RelayServer(SessionAuthenticator({secret},NonceReplayCache(clock=clock),clock),backend,maximumUdpFlows=1).apply { start(0) }
        try {
            Client(server.port).use { first ->
                first.hello(); first.send(DbpMessageType.OPEN_UDP,ExtensionCodec.encodeUdpOpen(UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443))))
                assertEquals(DbpMessageType.OPEN_UDP_OK,first.read().first)
                Client(server.port).use { second ->
                    second.hello(); second.send(DbpMessageType.OPEN_UDP,ExtensionCodec.encodeUdpOpen(UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443))))
                    val (type,payload)=second.read(); assertEquals(DbpMessageType.OPEN_UDP_ERROR,type)
                    assertEquals(DbpErrorCode.SESSION_LIMIT.code,payload[1].toInt())
                }
                first.socket.shutdownOutput()
                withTimeout(1500) { while(server.metrics.activeUdp()!=0) delay(5) }
            }
        } finally { server.stop() }
    }

    @Test fun `stop during pending UDP open closes late socket without opening flow`() = runBlocking {
        val entered=CompletableDeferred<Unit>(); val release=CompletableDeferred<Unit>()
        val remote=DatagramSocket().apply { connect(InetAddress.getLoopbackAddress(),9) }
        val backend=object: Backend() {
            override suspend fun connectUdp(destination: OpenDestination): DatagramSocket {
                entered.complete(Unit)
                withContext(NonCancellable) { release.await() }
                return remote
            }
        }
        val server=server(backend)
        try {
            Client(server.port).use { client ->
                client.hello(); client.send(DbpMessageType.OPEN_UDP,ExtensionCodec.encodeUdpOpen(UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443))))
                withTimeout(1500) { entered.await() }
                server.stop(); assertEquals(-1,client.input.read())
                release.complete(Unit)
                withTimeout(1500) { while(!remote.isClosed) delay(5) }
                assertEquals(0,server.metrics.activeUdp())
            }
        } finally { release.complete(Unit); server.stop(); remote.close() }
    }

    @Test fun `forty idle UDP plus twenty TCP flows leave health and default IO responsive`() = runBlocking {
        ServerSocket(0,128,InetAddress.getLoopbackAddress()).use { tcpListener ->
            DatagramSocket(0,InetAddress.getLoopbackAddress()).use { udpPeer ->
                val accepted=java.util.concurrent.CopyOnWriteArrayList<Socket>()
                val backend=object: Backend() {
                    override suspend fun connect(destination: OpenDestination): Socket = Socket(InetAddress.getLoopbackAddress(),tcpListener.localPort).also { accepted+=tcpListener.accept() }
                    override suspend fun connectUdp(destination: OpenDestination)=DatagramSocket().apply { connect(udpPeer.localSocketAddress) }
                }
                val server=server(backend)
                val clients=mutableListOf<Client>()
                try {
                    repeat(20) {
                        val client=Client(server.port); clients+=client; client.hello()
                        client.send(DbpMessageType.OPEN_TCP,DbpCodec.encodeOpenTcp(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443)))
                        assertEquals(DbpMessageType.OPEN_OK,client.read().first)
                    }
                    repeat(40) {
                        val client=Client(server.port); clients+=client; client.hello()
                        client.send(DbpMessageType.OPEN_UDP,ExtensionCodec.encodeUdpOpen(UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),443))))
                        assertEquals(DbpMessageType.OPEN_UDP_OK,client.read().first)
                    }
                    Client(server.port).use { client ->
                        client.hello(); client.send(DbpMessageType.HEALTH)
                        assertEquals(DbpMessageType.HEALTH_RESPONSE,client.read().first)
                    }
                    assertEquals(42,withTimeout(1500) { withContext(Dispatchers.IO) {42} })
                    assertEquals(40,server.metrics.activeUdp())
                } finally { clients.forEach {it.close()}; server.stop(); accepted.forEach {it.close()} }
            }
        }
    }

}
