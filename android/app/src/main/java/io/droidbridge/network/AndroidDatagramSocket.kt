package io.droidbridge.network

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.SocketAddress
import java.net.SocketException

/** Cellular datagram socket; created unbound so Network.bindSocket runs before connect. */
internal class AndroidDatagramSocket : DatagramSocket(null as SocketAddress?) {
    // DatagramSocket.receive can hold the socket monitor while blocked. Sending and closing
    // must use an independent lock so they can make progress beside the relay's receive worker.
    private val descriptorLock = Any()
    private var emptySendDescriptor: ParcelFileDescriptor? = null

    override fun send(packet: DatagramPacket) {
        synchronized(packet) {
            if (packet.length != 0 || !isConnected) {
                super.send(packet)
                return
            }
            val descriptor = synchronized(descriptorLock) {
                if (isClosed) throw SocketException("Socket is closed")
                // Match DatagramSocket's connected-destination validation before bypassing send.
                if (packet.address == null) {
                    packet.address = inetAddress
                    packet.port = port
                } else if (packet.address != inetAddress || packet.port != port) {
                    throw IllegalArgumentException("Connected address and packet address differ")
                }
                emptySendDescriptor ?: ParcelFileDescriptor.fromDatagramSocket(this).also { emptySendDescriptor = it }
            }
            // Android IoBridge.sendto treats a connected zero-byte send as a stream no-op.
            // Os.sendto reaches the kernel while retaining the connected peer and network binding.
            try {
                Os.sendto(descriptor.fileDescriptor, packet.data, packet.offset, 0, 0, null as InetAddress?, 0)
            } catch (error: ErrnoException) {
                throw IOException("Empty datagram send failed", error)
            }
        }
    }

    override fun close() = synchronized(descriptorLock) {
        // API26–28 wrappers borrow the socket's FileDescriptor; invalidate it by closing the
        // owner first. API29+ wrappers own a duplicate, which must also close to release the port.
        super.close()
        emptySendDescriptor?.let { runCatching { it.close() } }
        emptySendDescriptor = null
    }
}
