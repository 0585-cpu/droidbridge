package io.droidbridge.network

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.telephony.TelephonyManager
import java.net.InetAddress
import java.net.Socket

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
                callback.onAvailable(AndroidNetworkHandle(network), telephonyManager?.networkOperatorName)
            }
            override fun onLost(network: Network) {
                callback.onLost(AndroidNetworkHandle(network))
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
        (network as AndroidNetworkHandle).network.bindSocket(socket)
        return socket
    }

    override fun dnsServers(network: NetworkHandle): List<InetAddress> {
        val properties: LinkProperties? = connectivityManager.getLinkProperties((network as AndroidNetworkHandle).network)
        return properties?.dnsServers ?: emptyList()
    }
}
