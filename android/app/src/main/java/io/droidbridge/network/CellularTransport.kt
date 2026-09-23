package io.droidbridge.network

import java.net.InetAddress
import java.net.Socket
import java.net.DatagramSocket

/** Opaque handle to a selected cellular Network, so the controller is testable without Android. */
interface NetworkHandle

/** Callbacks mirror ConnectivityManager.NetworkCallback for the cellular request. */
interface CellularCallback {
    fun onAvailable(network: NetworkHandle, carrierName: String?)
    fun onLost(network: NetworkHandle)
    fun onChanged(network: NetworkHandle) {}
}

/** The only surface that touches the Android framework; faked in unit tests. */
interface ConnectivityFacade {
    fun requestCellular(callback: CellularCallback)
    fun unregister(callback: CellularCallback)
    fun resolve(network: NetworkHandle, domain: String): List<InetAddress>
    fun createSocket(network: NetworkHandle): Socket
    fun dnsServers(network: NetworkHandle): List<InetAddress>
    fun releaseSocket(socket: java.io.Closeable) {}
    fun createDatagramSocket(network: NetworkHandle): DatagramSocket = throw java.io.IOException("UDP unsupported")
    fun supportsIpv6(network: NetworkHandle): Boolean = false
    fun nat64Prefix(network: NetworkHandle): ByteArray? = null
    fun applyPolicy(socket: Socket, address: InetAddress, policy: SocketEgressPolicy) {
        if (policy != SocketEgressPolicy()) throw SocketPolicyException()
    }
    fun applyPolicy(socket: DatagramSocket, address: InetAddress, policy: SocketEgressPolicy) {
        if (policy != SocketEgressPolicy()) throw SocketPolicyException()
    }
}
