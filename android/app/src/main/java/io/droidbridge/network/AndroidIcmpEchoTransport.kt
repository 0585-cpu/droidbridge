package io.droidbridge.network

import android.system.Os
import android.system.OsConstants
import android.system.StructPollfd
import io.droidbridge.protocol.IcmpRequest
import io.droidbridge.protocol.IcmpReply
import io.droidbridge.relay.RelayTrafficPolicy
import java.io.Closeable
import java.io.FileDescriptor
import java.net.InetAddress
import java.net.Inet6Address
import java.net.SocketTimeoutException
import kotlinx.coroutines.*

/** Ping datagram sockets only (never SOCK_RAW). Availability is probed per cellular generation. */
class AndroidIcmpEchoTransport(private val controller: CellularNetworkController) {
    private class OwnedFd(val fd: FileDescriptor): Closeable {
        private var closed=false
        @Synchronized override fun close() { if(!closed) { closed=true; runCatching { Os.close(fd) } } }
    }
    private fun open(snapshot: CellularSnapshot,family: Int,policy: SocketEgressPolicy): OwnedFd {
        val handle=snapshot.network as? AndroidNetworkHandle ?: throw UnsupportedOperationException("ping unavailable")
        // Public Android docs define O_NONBLOCK/O_CLOEXEC as the pre-29 socket flags.
        val socket=OwnedFd(Os.socket(if(family==4) OsConstants.AF_INET else OsConstants.AF_INET6,OsConstants.SOCK_DGRAM or OsConstants.O_NONBLOCK or (if(android.os.Build.VERSION.SDK_INT>=27) OsConstants.O_CLOEXEC else 0),
            if(family==4) OsConstants.IPPROTO_ICMP else OsConstants.IPPROTO_ICMPV6))
        try {
            controller.track(snapshot,socket)
            handle.network.bindSocket(socket.fd)
            val address=if(family==4) InetAddress.getByAddress(ByteArray(4)) else Inet6Address.getByAddress(null,ByteArray(16),-1)
            AndroidSocketPolicyApplier.apply(socket.fd,address,policy)
            controller.requireCurrent(snapshot)
            return socket
        } catch(e: Exception) { socket.close(); controller.release(socket); throw e }
    }
    fun probe(family: Int,policy: SocketEgressPolicy): Boolean {
        if(family==6 && !controller.ipv6Available()) return false
        return try {
            val socket=open(controller.snapshot(),family,policy)
            socket.close(); controller.release(socket); true
        } catch(_: Exception) { false }
    }
    suspend fun echo(request: IcmpRequest,traffic: RelayTrafficPolicy): IcmpReply = withContext(Dispatchers.IO) {
        val snapshot=controller.snapshot()
        val address=if(request.family==4) InetAddress.getByAddress(request.destination) else Inet6Address.getByAddress(null,request.destination,-1)
        controller.requireAllowed(address)
        val base=traffic.profile.socketPolicy
        val policy=if(request.family==4) base.copy(ipv4Ttl=base.ipv4Ttl ?: request.ttl.takeIf {it>0}) else base.copy(ipv6HopLimit=base.ipv6HopLimit ?: request.ttl.takeIf {it>0})
        val socket=open(snapshot,request.family,policy)
        val closer=launch(Dispatchers.IO,start=CoroutineStart.UNDISPATCHED) { try { awaitCancellation() } finally { socket.close() } }
        try {
            Os.connect(socket.fd,address,0)
            val bytes=IcmpPackets.request(request)
            traffic.upload(bytes.size)
            controller.requireCurrent(snapshot); ensureActive()
            val sent=System.nanoTime()
            if(Os.write(socket.fd,bytes,0,bytes.size)!=bytes.size) throw java.io.IOException("short ICMP send")
            val poll=StructPollfd().apply { fd=socket.fd; events=OsConstants.POLLIN.toShort() }
            val buffer=ByteArray(1209)
            while(System.nanoTime()-sent<3_000_000_000L) {
                ensureActive(); controller.requireCurrent(snapshot)
                if(Os.poll(arrayOf(poll),100)<=0) continue
                val length=Os.read(socket.fd,buffer,0,buffer.size)
                val reply=buffer.copyOf(length)
                if(!IcmpPackets.matches(reply,request)) continue
                val elapsed=(System.nanoTime()-sent)/1000
                traffic.download(length); controller.requireCurrent(snapshot)
                return@withContext IcmpReply(request.requestId,request.family,address.address,request.payload,elapsed)
            }
            throw SocketTimeoutException("ICMP echo timed out")
        } finally { socket.close(); controller.release(socket); closer.cancel() }
    }
}
