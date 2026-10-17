package io.droidbridge.relay

import io.droidbridge.protocol.*
import io.droidbridge.security.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.io.*
import java.net.*
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicLong

class UdpAssociationServerTest {
    private val secret=ByteArray(32) { 7 }
    private val clock=EpochClock { 1700000000 }
    private val nonce=AtomicLong(500)
    private val loopback=InetAddress.getByName("127.0.0.1")
    private inner class Client(val socket: Socket) : AutoCloseable {
        constructor(port: Int) : this(Socket(loopback,port))
        init { socket.soTimeout=2000 }
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
        fun open() { hello(); send(DbpMessageType.OPEN_UDP_ASSOCIATION,byteArrayOf(4,0,0,30)); assertEquals(DbpMessageType.OPEN_UDP_OK,read().first) }
        override fun close()=socket.close()
    }
    private open class Backend : RelayBackend {
        val sockets=java.util.concurrent.CopyOnWriteArrayList<DatagramSocket>()
        override suspend fun connect(destination: OpenDestination): Socket=error("unexpected TCP")
        override suspend fun resolveDns(queryPacket: ByteArray): ByteArray=error("unexpected DNS")
        override fun cellularReady()=true
        override fun carrierName()="test"
        override fun capabilities()=RelayCapabilities(flags=Capability.UDP4 or Capability.UDP_ASSOCIATION)
        // Match CellularNetworkController: bind before concurrent send/receive workers start.
        override suspend fun openUdpAssociation(family: Int): DatagramSocket=
            DatagramSocket(0,InetAddress.getByName("127.0.0.1")).also { sockets+=it }
        override fun requireUdpDestination(address: InetAddress) { require(address.isLoopbackAddress) }
    }
    private fun server(backend: RelayBackend,limit: Int=256)=RelayServer(SessionAuthenticator({secret},NonceReplayCache(clock=clock),clock),backend,maximumUdpFlows=limit).apply { start(0) }
    // Independent wire builder: changing the production peer slot, direction or byte order breaks these exchanges.
    private fun wire(port: Int,data: ByteArray,sequence: Int=0): ByteArray = ByteBuffer.allocate(28+data.size)
        .putShort(data.size.toShort()).put(0).put(4).putInt(sequence).putShort(port.toShort()).putShort(0)
        .put(byteArrayOf(127,0,0,1)).put(ByteArray(12)).put(data).array()
    private fun receive(socket: DatagramSocket): DatagramPacket = DatagramPacket(ByteArray(2000),2000).also(socket::receive)
    private fun readReply(client: Client,port: Int,data: ByteArray) {
        assertEquals(data.size,client.input.readUnsignedShort()); assertEquals(1,client.input.readUnsignedByte()); assertEquals(4,client.input.readUnsignedByte())
        client.input.readInt(); assertEquals(port,client.input.readUnsignedShort()); assertEquals(0,client.input.readUnsignedShort())
        assertArrayEquals(byteArrayOf(127,0,0,1)+ByteArray(12),ByteArray(16).also(client.input::readFully))
        assertArrayEquals(data,ByteArray(data.size).also(client.input::readFully))
    }
    @Test fun `one authenticated association shares source port across two peers and drops unsolicited third peer`() = runBlocking {
        val backend=Backend(); val server=server(backend)
        DatagramSocket(0,loopback).use { first -> DatagramSocket(0,loopback).use { second -> DatagramSocket(0,loopback).use { third ->
            first.soTimeout=2000; second.soTimeout=2000
            try {
                Client(server.port).use { client ->
                    client.open()
                    client.output.write(wire(first.localPort,byteArrayOf(1)))
                    val a=withContext(Dispatchers.IO) { receive(first) }
                    client.output.write(wire(second.localPort,byteArrayOf(2),1))
                    val b=withContext(Dispatchers.IO) { receive(second) }
                    assertEquals(a.port,b.port)
                    assertEquals(1,backend.sockets.size)
                    assertFalse(backend.sockets.single().isConnected)
                    third.send(DatagramPacket(byteArrayOf(99),1,a.socketAddress))
                    withTimeout(1500) { while(server.metrics.udpDrops()<1) delay(5) }
                    first.send(DatagramPacket(byteArrayOf(11),1,a.socketAddress))
                    readReply(client,first.localPort,byteArrayOf(11))
                    second.send(DatagramPacket(byteArrayOf(22),1,b.socketAddress))
                    readReply(client,second.localPort,byteArrayOf(22))
                    Client(server.port).use { other ->
                        other.open(); other.output.write(wire(first.localPort,byteArrayOf(3)))
                        val c=withContext(Dispatchers.IO) { receive(first) }; assertNotEquals(a.port,c.port)
                    }
                    client.socket.shutdownOutput()
                    withTimeout(1500) { while(backend.sockets.any { !it.isClosed }) delay(5) }
                }
            } finally { server.stop() }
        } } }
    }
    @Test fun `zero and maximum datagrams roundtrip while oversized inbound datagram is dropped`() = runBlocking {
        val backend=Backend(); val server=server(backend)
        DatagramSocket(0,loopback).use { peer ->
            peer.soTimeout=2000
            try { Client(server.port).use { client ->
                client.open()
                for(size in listOf(0,1232)) {
                    val data=ByteArray(size) { 7 }
                    client.output.write(wire(peer.localPort,data,size))
                    val packet=withContext(Dispatchers.IO) { receive(peer) }
                    assertArrayEquals(data,packet.data.copyOf(packet.length))
                    peer.send(DatagramPacket(data,data.size,packet.socketAddress))
                    readReply(client,peer.localPort,data)
                    if(size==1232) {
                        val before=server.metrics.udpDrops()
                        peer.send(DatagramPacket(ByteArray(1233),1233,packet.socketAddress))
                        withTimeout(1500) { while(server.metrics.udpDrops()==before) delay(5) }
                        peer.send(DatagramPacket(byteArrayOf(5),1,packet.socketAddress))
                        readReply(client,peer.localPort,byteArrayOf(5))
                    }
                }
            } } finally { server.stop() }
        }
    }
    @Test fun `association requires authentication`() {
        val backend=Backend(); val server=server(backend)
        try { Client(server.port).use { client ->
            client.send(DbpMessageType.OPEN_UDP_ASSOCIATION,byteArrayOf(4,0,0,30))
            assertEquals(-1,client.input.read()); assertTrue(backend.sockets.isEmpty())
        } } finally { server.stop() }
    }
    @Test fun `malformed association packet closes socket and returns capacity`() = runBlocking {
        val backend=Backend(); val server=server(backend,1)
        try {
            for(bad in listOf(wire(9,byteArrayOf(1)).also { it[2]=1 },wire(9,byteArrayOf(1)).also { it[3]=6 },wire(9,byteArrayOf(1)).also { it[10]=1 },wire(9,ByteArray(1233)),wire(9,byteArrayOf(1)).also { it[16]=1 },wire(0,byteArrayOf(1)))) {
                Client(server.port).use { client ->
                    client.open(); client.output.write(bad)
                    try { assertEquals(-1,client.input.read()) } catch(_: SocketException) { /* reset is valid with unread malformed bytes */ }
                    withTimeout(1500) { while(server.metrics.activeUdp()!=0) delay(5) }
                }
            }
            assertTrue(backend.sockets.all { it.isClosed })
            assertEquals(6,server.metrics.udpDrops())
        } finally { server.stop() }
    }
    @Test fun `stop during association open closes late socket without publishing it`() = runBlocking {
        val entered=CompletableDeferred<Unit>(); val release=CompletableDeferred<Unit>()
        val remote=DatagramSocket()
        val backend=object: Backend() {
            override suspend fun openUdpAssociation(family: Int): DatagramSocket {
                entered.complete(Unit); withContext(NonCancellable) { release.await() }; return remote
            }
        }
        val server=server(backend)
        try { Client(server.port).use { client ->
            client.hello(); client.send(DbpMessageType.OPEN_UDP_ASSOCIATION,byteArrayOf(4,0,0,30))
            withTimeout(1500) { entered.await() }
            server.stop(); assertEquals(-1,client.input.read())
            release.complete(Unit)
            withTimeout(1500) { while(!remote.isClosed) delay(5) }
            assertEquals(0,server.metrics.activeUdp())
        } } finally { release.complete(Unit); server.stop(); remote.close() }
    }
    @Test fun `association and legacy UDP consume the same capacity limit`() = runBlocking {
        val backend=object: Backend() {
            override suspend fun connectUdp(destination: OpenDestination)=DatagramSocket().apply { connect(loopback,9) }
        }
        val server=server(backend,1)
        try { Client(server.port).use { first ->
            first.open()
            Client(server.port).use { second ->
                second.hello(); second.send(DbpMessageType.OPEN_UDP,ExtensionCodec.encodeUdpOpen(UdpOpen(OpenDestination.Ipv4(byteArrayOf(8,8,8,8),53))))
                val result=second.read(); assertEquals(DbpMessageType.OPEN_UDP_ERROR,result.first)
                assertArrayEquals(byteArrayOf(0,8,0,0),result.second)
            }
            first.socket.shutdownOutput()
            withTimeout(1500) { while(server.metrics.activeUdp()!=0) delay(5) }
            Client(server.port).use { it.open() }
        } } finally { server.stop() }
    }
    @Test fun `unsupported association and unavailable family return signed errors`() {
        for(flags in listOf(Capability.UDP4,Capability.UDP6 or Capability.UDP_ASSOCIATION)) {
            val backend=object: Backend() { override fun capabilities()=RelayCapabilities(flags=flags) }
            val server=server(backend)
            try { Client(server.port).use { client ->
                client.hello(); client.send(DbpMessageType.OPEN_UDP_ASSOCIATION,byteArrayOf(4,0,0,30))
                val result=client.read(); assertEquals(DbpMessageType.OPEN_UDP_ERROR,result.first)
                assertArrayEquals(byteArrayOf(0,if(flags==Capability.UDP4) 10 else 14,0,0),result.second)
                assertTrue(backend.sockets.isEmpty())
            } } finally { server.stop() }
        }
    }
    @Test fun `per packet destination policy prevents denied traffic without retiring association`() = runBlocking {
        val backend=object: Backend() {
            override fun requireUdpDestination(address: InetAddress)=io.droidbridge.policy.DestinationPolicy.requireAllowed(address)
        }
        val server=server(backend)
        DatagramSocket(0,loopback).use { peer ->
            try { Client(server.port).use { client ->
                client.open(); client.output.write(wire(peer.localPort,byteArrayOf(7)))
                withTimeout(1500) { while(server.metrics.udpDrops()<1) delay(5) }
                peer.soTimeout=100
                try { receive(peer); fail("denied destination received packet") } catch(_: SocketTimeoutException) {}
                assertEquals(1,server.metrics.activeUdp())
            } } finally { server.stop() }
        }
    }


    @Test fun `association over an in-memory AOA stream relays a burst both ways in order`() = runBlocking {
        val backend=Backend(); val server=server(backend)
        ServerSocket(0).use { usb -> Socket(loopback,usb.localPort).use { host ->
            val accessory=usb.accept()
            val bridge=io.droidbridge.usb.AoaAccessoryBridge(accessory.getInputStream(),accessory.getOutputStream(),
                closeTransport={ accessory.close() },relayAcceptor=server::accept)
            bridge.start()
            // The Mac end of the same stream, built from the production pipe over the AOA wire.
            val hostOut=host.getOutputStream()
            val mac=io.droidbridge.usb.AoaPipeSocket(1,{ synchronized(hostOut) { hostOut.write(it) } }) {}
            val opened=java.util.concurrent.CountDownLatch(1)
            val ready=java.util.concurrent.CountDownLatch(1)
            val hostInput=BufferedInputStream(host.getInputStream())
            Thread {
                runCatching {
                    while(true) {
                        val f=io.droidbridge.usb.AoaFrame.read(hostInput) ?: break
                        when(f.type) {
                            io.droidbridge.usb.AoaFrame.RESET_OK -> ready.countDown()
                            io.droidbridge.usb.AoaFrame.OPEN_OK -> opened.countDown()
                            io.droidbridge.usb.AoaFrame.DATA -> mac.deliver(f.payload)
                            io.droidbridge.usb.AoaFrame.WINDOW -> mac.credit(f.credit())
                            io.droidbridge.usb.AoaFrame.FIN -> mac.remoteFinished()
                            io.droidbridge.usb.AoaFrame.CLOSE -> mac.abort()
                        }
                    }
                }
            }.apply { isDaemon=true; start() }
            DatagramSocket(0,loopback).use { peer ->
                peer.soTimeout=2000
                try {
                    // Like the Mac mux: no stream opens before the RESET_OK barrier.
                    synchronized(hostOut) { hostOut.write(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.RESET,0,payload=ByteArray(16)).encode()) }
                    assertTrue(ready.await(2,java.util.concurrent.TimeUnit.SECONDS))
                    synchronized(hostOut) { hostOut.write(io.droidbridge.usb.AoaFrame(io.droidbridge.usb.AoaFrame.OPEN,1,io.droidbridge.usb.AoaFrame.RELAY).encode()) }
                    assertTrue(opened.await(2,java.util.concurrent.TimeUnit.SECONDS))
                    Client(mac).use { client ->
                        client.open()
                        client.output.write(wire(peer.localPort,byteArrayOf(1)))
                        val first=withContext(Dispatchers.IO) { receive(peer) }
                        // A Parsec-like burst: many small datagrams back to the Mac, in order.
                        repeat(200) { peer.send(DatagramPacket(byteArrayOf(it.toByte(),9),2,first.socketAddress)) }
                        repeat(200) { readReply(client,peer.localPort,byteArrayOf(it.toByte(),9)) }
                    }
                } finally { bridge.close(); server.stop() }
            }
        } }
    }
}
