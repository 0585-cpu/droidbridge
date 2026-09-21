package io.droidbridge.network

import android.net.Network
import java.io.DataInputStream
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Real DNS transport: every socket is bound to the selected cellular [network]. Port 53, 4096-byte cap. */
class AndroidDnsTransport(
    private val network: Network,
    private val servers: () -> List<InetAddress>,
) : DnsTransport {
    override fun dnsServers(): List<InetAddress> = servers()

    override suspend fun queryUdp(server: InetAddress, packet: ByteArray, timeoutMs: Int): ByteArray = withContext(Dispatchers.IO) {
        val socket = DatagramSocket(null)
        try {
            network.bindSocket(socket)
            socket.soTimeout = timeoutMs
            socket.connect(InetSocketAddress(server, 53))
            socket.send(DatagramPacket(packet, packet.size))
            val buffer = ByteArray(DnsWire.MAX_PACKET)
            val response = DatagramPacket(buffer, buffer.size)
            try {
                socket.receive(response)
            } catch (e: SocketTimeoutException) {
                throw DnsTimeoutException()
            }
            buffer.copyOf(response.length)
        } finally {
            socket.close()
        }
    }

    override suspend fun queryTcp(server: InetAddress, packet: ByteArray, timeoutMs: Int): ByteArray = withContext(Dispatchers.IO) {
        val socket = java.net.Socket()
        try {
            network.bindSocket(socket)
            socket.connect(InetSocketAddress(server, 53), timeoutMs)
            socket.soTimeout = timeoutMs
            val out = socket.getOutputStream()
            out.write((packet.size shr 8) and 0xFF)
            out.write(packet.size and 0xFF)
            out.write(packet)
            out.flush()
            val input = DataInputStream(socket.getInputStream())
            val length = try { input.readUnsignedShort() } catch (e: SocketTimeoutException) { throw DnsTimeoutException() }
            if (length !in DnsWire.MIN_PACKET..DnsWire.MAX_PACKET) throw DnsFailureException(DnsFailure.MALFORMED)
            ByteArray(length).also { input.readFully(it) }
        } finally {
            socket.close()
        }
    }
}
