package io.droidbridge.network

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.telephony.TelephonyManager
import java.net.InetAddress
import java.net.Socket
import java.net.DatagramSocket
import java.net.Inet6Address
import android.os.Build

/** Wraps a framework Network so the controller stays framework-free. */
class AndroidNetworkHandle(val network: Network) : NetworkHandle {
    override fun equals(other: Any?): Boolean = other is AndroidNetworkHandle && other.network == network
    override fun hashCode(): Int = network.hashCode()
}

/** Real ConnectivityFacade: binds every outbound socket to the selected cellular Network. */
class AndroidCellularTransport(
    private val connectivityManager: ConnectivityManager,
    private val telephonyManager: TelephonyManager?,
) : ConnectivityFacade {

    private var frameworkCallback: ConnectivityManager.NetworkCallback? = null

    override fun requestCellular(callback: CellularCallback) {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val fw = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                if(frameworkCallback === this) callback.onAvailable(AndroidNetworkHandle(network), telephonyManager?.networkOperatorName)
            }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
                if(frameworkCallback === this) callback.onChanged(AndroidNetworkHandle(network))
            }
            override fun onLost(network: Network) {
                if(frameworkCallback === this) callback.onLost(AndroidNetworkHandle(network))
            }
        }
        frameworkCallback = fw
        connectivityManager.requestNetwork(request, fw)
    }

    override fun unregister(callback: CellularCallback) {
        frameworkCallback?.let { connectivityManager.unregisterNetworkCallback(it) }
        frameworkCallback = null
    }

    override fun resolve(network: NetworkHandle, domain: String): List<InetAddress> =
        (network as AndroidNetworkHandle).network.getAllByName(domain).toList()

    override fun createSocket(network: NetworkHandle): Socket {
        val socket = Socket()
        try { (network as AndroidNetworkHandle).network.bindSocket(socket); return socket }
        catch(e: Exception) { socket.close(); throw e }
    }

    override fun releaseSocket(socket: java.io.Closeable) = AndroidSocketPolicyApplier.release(socket)
    override fun createDatagramSocket(network: NetworkHandle): DatagramSocket {
        val socket=DatagramSocket(null)
        try { (network as AndroidNetworkHandle).network.bindSocket(socket); return socket }
        catch(e: Exception) { socket.close(); throw e }
    }
    override fun applyPolicy(socket: Socket,address: InetAddress,policy: SocketEgressPolicy) = AndroidSocketPolicyApplier.apply(socket,address,policy)
    override fun applyPolicy(socket: DatagramSocket,address: InetAddress,policy: SocketEgressPolicy) = AndroidSocketPolicyApplier.apply(socket,address,policy)
    override fun supportsIpv6(network: NetworkHandle): Boolean {
        val p=connectivityManager.getLinkProperties((network as AndroidNetworkHandle).network) ?: return false
        return p.linkAddresses.any { it.address is Inet6Address && !it.address.isLinkLocalAddress && !it.address.isAnyLocalAddress } &&
            p.routes.any { it.isDefaultRoute && it.destination.address is Inet6Address }
    }
    override fun nat64Prefix(network: NetworkHandle): ByteArray? {
        if(Build.VERSION.SDK_INT < 30) return null
        val prefix=connectivityManager.getLinkProperties((network as AndroidNetworkHandle).network)?.nat64Prefix ?: return null
        return if(prefix.prefixLength==96) prefix.address.address else null
    }

    override fun dnsServers(network: NetworkHandle): List<InetAddress> {
        val properties: LinkProperties? = connectivityManager.getLinkProperties((network as AndroidNetworkHandle).network)
        return properties?.dnsServers ?: emptyList()
    }
}
