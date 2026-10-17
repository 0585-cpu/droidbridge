package io.droidbridge.network

import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.RouteInfo
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

    @Volatile private var frameworkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var selectedProperties: NetworkProperties? = null

    private data class AddressPrefix(val bytes: List<Byte>,val prefixLength: Int)
    private data class TransportIdentity(
        val interfaceName: String?,
        val addresses: Set<AddressPrefix>,
        val routes: Set<RouteInfo>,
        val nat64Prefix: IpPrefix?,
    )
    /** Own only immutable values, never the mutable LinkProperties supplied by the framework. */
    private data class NetworkProperties(
        val network: Network,
        val identity: TransportIdentity,
        val ipv6Available: Boolean,
        val nat64Prefix: ByteArray?,
        val dnsServers: List<InetAddress>,
    )

    private fun transportIdentity(properties: LinkProperties) = TransportIdentity(
        properties.interfaceName,
        properties.linkAddresses.map { AddressPrefix(it.address.address.toList(),it.prefixLength) }.toSet(),
        properties.routes.toSet(),
        if(Build.VERSION.SDK_INT>=30) properties.nat64Prefix else null,
    )
    private fun snapshot(network: Network, properties: LinkProperties): NetworkProperties {
        val identity=transportIdentity(properties)
        return NetworkProperties(network,identity,
            properties.linkAddresses.any { it.address is Inet6Address && !it.address.isLinkLocalAddress && !it.address.isAnyLocalAddress } &&
                properties.routes.any { it.isDefaultRoute && it.destination.address is Inet6Address },
            identity.nat64Prefix?.takeIf { it.prefixLength==96 }?.address?.address,
            properties.dnsServers.toList())
    }
    private fun propertiesFor(network: NetworkHandle): NetworkProperties? =
        selectedProperties?.takeIf { it.network == (network as AndroidNetworkHandle).network }

    // The controller already serializes lifecycle and policy on this callback object. Reuse that
    // monitor so a complete policy check cannot mix snapshots, without adding a second lock order.
    override fun requestCellular(callback: CellularCallback) = synchronized(callback) {
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val fw = object : ConnectivityManager.NetworkCallback() {
            private var selected: Network? = null

            override fun onAvailable(network: Network): Unit = synchronized(callback) {
                if(frameworkCallback !== this) return
                if(selected != network) { selected=network; selectedProperties=null }
                callback.onAvailable(AndroidNetworkHandle(network), telephonyManager?.networkOperatorName)
            }
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties): Unit = synchronized(callback) {
                if(frameworkCallback !== this || selected != network) return
                // The first callback seeds the baseline. A synchronous getter in onAvailable can
                // return stale properties; DNS/proxy metadata and ordering do not change a path.
                val next=snapshot(network,properties)
                val previous=selectedProperties
                selectedProperties=next
                // Stacked CLAT details are not exposed by the public SDK. Do not infer changes
                // from opaque LinkProperties equality; network loss and socket I/O still apply.
                if(previous != null && previous.identity != next.identity) callback.onChanged(AndroidNetworkHandle(network))
            }
            override fun onLost(network: Network): Unit = synchronized(callback) {
                if(frameworkCallback !== this) return
                if(selected == network) { selected=null; selectedProperties=null }
                callback.onLost(AndroidNetworkHandle(network))
            }
        }
        frameworkCallback = fw
        selectedProperties = null
        try { connectivityManager.requestNetwork(request, fw) }
        catch(error: Exception) {
            // A failed registration owns no usable callbacks, even if delivery was already queued.
            if(frameworkCallback === fw) { frameworkCallback=null; selectedProperties=null }
            runCatching { connectivityManager.unregisterNetworkCallback(fw) }
            throw error
        }
    }

    override fun unregister(callback: CellularCallback) = synchronized(callback) {
        val previous=frameworkCallback
        frameworkCallback = null
        selectedProperties = null
        previous?.let { connectivityManager.unregisterNetworkCallback(it) }
        Unit
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
        val socket=AndroidDatagramSocket()
        try { (network as AndroidNetworkHandle).network.bindSocket(socket); return socket }
        catch(e: Exception) { socket.close(); throw e }
    }
    override fun applyPolicy(socket: Socket,address: InetAddress,policy: SocketEgressPolicy) = AndroidSocketPolicyApplier.apply(socket,address,policy)
    override fun applyPolicy(socket: DatagramSocket,address: InetAddress,policy: SocketEgressPolicy) = AndroidSocketPolicyApplier.apply(socket,address,policy)
    override fun supportsUdpAssociation(network: NetworkHandle): Boolean = true
    override fun supportsIpv6(network: NetworkHandle): Boolean = propertiesFor(network)?.ipv6Available ?: false
    override fun nat64Prefix(network: NetworkHandle): ByteArray? = propertiesFor(network)?.nat64Prefix?.copyOf()

    override fun dnsServers(network: NetworkHandle): List<InetAddress> = propertiesFor(network)?.dnsServers?.toList() ?: emptyList()
}
