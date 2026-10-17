package io.droidbridge.network

import android.net.Network
import io.droidbridge.relay.RelayTrafficPolicy
import java.io.DataInputStream
import java.io.Closeable
import java.net.*
import kotlinx.coroutines.*

/** Every DNS UDP attempt and TCP retry uses the same network generation and traffic profile. */
class AndroidDnsTransport(
    private val network: Network,
    private val policy: SocketEgressPolicy=SocketEgressPolicy(),
    private val traffic: RelayTrafficPolicy=RelayTrafficPolicy(),
    private val controller: CellularNetworkController?=null,
    private val snapshot: CellularSnapshot?=null,
    private val servers: () -> List<InetAddress>,
) : DnsTransport {
    override fun dnsServers(): List<InetAddress> = servers()
    private fun current() { snapshot?.let { controller!!.requireCurrent(it) } }
    private suspend fun <T> tracked(socket: Closeable,block: suspend () -> T): T = coroutineScope {
        snapshot?.let { controller!!.track(it,socket) }
        val closer=launch(Dispatchers.IO,start=CoroutineStart.UNDISPATCHED) { try { awaitCancellation() } finally { socket.close() } }
        try { current(); block().also { current() } }
        finally { socket.close(); AndroidSocketPolicyApplier.release(socket); controller?.release(socket); closer.cancel() }
    }
    override suspend fun queryUdp(server: InetAddress,packet: ByteArray,timeoutMs: Int): ByteArray = withContext(Dispatchers.IO) {
        // Preserve UDP datagram atomicity even with the smallest allowed burst.
        if(packet.size>traffic.profile.burstBytes) return@withContext queryTcp(server,packet,timeoutMs)
        val socket=DatagramSocket(null)
        tracked(socket) {
            network.bindSocket(socket)
            AndroidSocketPolicyApplier.apply(socket,server,policy)
            socket.soTimeout=timeoutMs
            current(); socket.connect(InetSocketAddress(server,53))
            traffic.upload(packet.size); current()
            socket.send(DatagramPacket(packet,packet.size))
            val response=DatagramPacket(ByteArray(DnsWire.MAX_PACKET+1),DnsWire.MAX_PACKET+1)
            try { socket.receive(response) } catch(e: SocketTimeoutException) { throw DnsTimeoutException() }
            if(response.length>DnsWire.MAX_PACKET) throw DnsFailureException(DnsFailure.MALFORMED)
            response.data.copyOf(response.length)
        }
    }
    override suspend fun queryTcp(server: InetAddress,packet: ByteArray,timeoutMs: Int): ByteArray = withContext(Dispatchers.IO) {
        val socket=Socket()
        tracked(socket) {
            network.bindSocket(socket)
            AndroidSocketPolicyApplier.apply(socket,server,policy)
            current(); socket.connect(InetSocketAddress(server,53),timeoutMs)
            socket.soTimeout=timeoutMs
            current()
            val frame=byteArrayOf((packet.size shr 8).toByte(),packet.size.toByte())+packet
            traffic.writeUpload(socket.getOutputStream(),frame)
            val input=DataInputStream(socket.getInputStream())
            try {
                val length=input.readUnsignedShort()
                if(length !in DnsWire.MIN_PACKET..DnsWire.MAX_PACKET) throw DnsFailureException(DnsFailure.MALFORMED)
                val answer=ByteArray(length).also(input::readFully)
                answer
            } catch(e: SocketTimeoutException) { throw DnsTimeoutException() }
        }
    }
}
