package io.droidbridge.network

import android.os.Build
import android.os.ParcelFileDescriptor
import android.system.Os
import android.system.OsConstants
import java.io.FileDescriptor
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket

/** Uses only public APIs; owns a duplicated descriptor, never the socket's borrowed descriptor. */
object AndroidSocketPolicyApplier {
    private val ownership=SocketDescriptorOwnership()
    fun release(socket: java.io.Closeable) = ownership.release(socket)

    fun apply(socket: Socket,address: InetAddress,policy: SocketEgressPolicy) {
        if(value(address,policy)==null) return
        withDuplicate(socket,ParcelFileDescriptor.fromSocket(socket)) { apply(it,address,policy) }
    }
    fun apply(socket: DatagramSocket,address: InetAddress,policy: SocketEgressPolicy) {
        if(value(address,policy)==null) return
        withDuplicate(socket,ParcelFileDescriptor.fromDatagramSocket(socket)) { apply(it,address,policy) }
    }
    private fun withDuplicate(owner: java.io.Closeable,wrapper: ParcelFileDescriptor, action: (FileDescriptor) -> Unit) {
        ownership.useDuplicate(owner,wrapper,Build.VERSION.SDK_INT < 29,{ it.dup() }) { action(it.fileDescriptor) }
    }
    private fun value(address: InetAddress,policy: SocketEgressPolicy): Int? = if(address.address.size==4) policy.ipv4Ttl else policy.ipv6HopLimit
    fun apply(fd: FileDescriptor,address: InetAddress,policy: SocketEgressPolicy) {
        val wanted=value(address,policy) ?: return
        val level=if(address.address.size==4) OsConstants.IPPROTO_IP else OsConstants.IPPROTO_IPV6
        val option=if(address.address.size==4) OsConstants.IP_TTL else OsConstants.IPV6_UNICAST_HOPS
        try {
            Os.setsockoptInt(fd,level,option,wanted)
            ParcelFileDescriptor.dup(fd).use { duplicate ->
                if(!NativeSocketOptions.matches(duplicate.fd,level,option,wanted)) throw SocketPolicyException()
            }
        } catch(e: Exception) { throw SocketPolicyException() } catch(e: LinkageError) { throw SocketPolicyException() }
    }
}
