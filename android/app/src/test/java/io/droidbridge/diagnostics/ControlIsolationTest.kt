package io.droidbridge.diagnostics
import io.droidbridge.network.*
import io.droidbridge.protocol.*
import io.droidbridge.relay.*
import io.droidbridge.security.*
import java.net.*
import java.io.DataInputStream
import java.util.concurrent.*
import kotlin.test.*
import kotlinx.coroutines.*

class ControlIsolationTest {
  private val secret=ByteArray(32){1}
  private val clock=object: EpochClock { override fun epochSeconds()=1_700_000_000L }
  private inner class Client(port:Int,val nonce:Long): AutoCloseable {
    val socket=Socket("127.0.0.1",port).apply{soTimeout=3000}
    val input=DataInputStream(socket.getInputStream())
    var sn=0L
    fun send(type:DbpMessageType,payload:ByteArray=byteArrayOf()) {
      val h=DbpHeader(type,0,nonce,sn,clock.epochSeconds(),ByteArray(32))
      socket.getOutputStream().write(DbpCodec.encodeHeader(h,DbpHmac.compute(secret,h,payload))+payload)
    }
    fun read():DbpHeader {
      val h=DbpCodec.decodeHeader(ByteArray(64).also{input.readFully(it)})
      val prefix=ByteArray(DbpCodec.payloadPrefixLength(h.type)).also{input.readFully(it)}
      input.readFully(ByteArray(DbpCodec.payloadRemaining(h.type,prefix)))
      return h
    }
    fun hello(){send(DbpMessageType.HELLO);val h=read();assertEquals(DbpMessageType.HELLO_OK,h.type);sn=h.serverNonce}
    override fun close(){socket.close()}
  }
  @Test fun blockedCellularConnectsLeaveHealthResponsive() {
    val limit=32 // bounded upstream workers are separate from control IO
    val release=CountDownLatch(1)
    val entered=CountDownLatch(limit)
    val attempts=java.util.concurrent.atomic.AtomicInteger()
    val network=object:NetworkHandle{}
    val facade=object:ConnectivityFacade {
      override fun requestCellular(callback:CellularCallback){callback.onAvailable(network,"Test")}
      override fun unregister(callback:CellularCallback){}
      override fun resolve(network:NetworkHandle,domain:String)=listOf(InetAddress.getByName("93.184.216.34"))
      override fun dnsServers(network:NetworkHandle)=emptyList<InetAddress>()
      override fun createSocket(network:NetworkHandle)=object:Socket(){
        override fun connect(endpoint:SocketAddress?,timeout:Int){
          attempts.incrementAndGet(); entered.countDown()
          release.await(timeout.toLong(),TimeUnit.MILLISECONDS)
          throw SocketTimeoutException("controlled upstream connect timeout")
        }
      }
    }
    val controller=CellularNetworkController(facade).also{it.start()}
    val backend=object:RelayBackend {
      override suspend fun connect(destination:OpenDestination)=controller.connectTcp(destination)
      override suspend fun resolveDns(queryPacket:ByteArray)=byteArrayOf()
      override fun carrierName()="Test"
      override fun cellularReady()=true
    }
    val server=RelayServer(SessionAuthenticator({secret},NonceReplayCache(clock=clock),clock),backend)
    val jobs=CoroutineScope(Dispatchers.Default+SupervisorJob())
    try {
      server.start(0)
      fun health(nonce:Long):Long {
        val start=System.nanoTime()
        Client(server.port,nonce).use{it.hello();it.send(DbpMessageType.HEALTH);assertEquals(DbpMessageType.HEALTH_RESPONSE,it.read().type)}
        return (System.nanoTime()-start)/1_000_000
      }
      println("baseline_health_ms="+health(1000))
      // Exercise actual production connect code independently from relay HELLO reads,
      // so the sole induced fault is slow upstream connects, never USB or cellular I/O.
      repeat(64){ jobs.launch { runCatching {
        controller.connectTcp(OpenDestination.Ipv4(byteArrayOf(93,184.toByte(),216.toByte(),34),443))
      } } }
      assertTrue(entered.await(3,TimeUnit.SECONDS),"did not saturate IO pool")
      Thread.sleep(100)
      assertTrue(attempts.get() <= 32, "Upstream attempts are not capped")
      println("blocked_connects="+attempts.get())
      val start=System.nanoTime()
      assertTrue(health(1001) < 1500, "HEALTH was blocked by upstream attempts")
      println("health_timeout_ms="+(System.nanoTime()-start)/1_000_000)
      release.countDown()
      Thread.sleep(200)
      println("recovered_health_ms="+health(1002))
    } finally {release.countDown();jobs.cancel();server.stop();controller.stop()}
  }
}
