package io.droidbridge.network

import java.net.InetAddress
import java.net.Socket

/** Opaque handle to a selected cellular Network, so the controller is testable without Android. */
interface NetworkHandle

/** Callbacks mirror ConnectivityManager.NetworkCallback for the cellular request. */
interface CellularCallback {
    fun onAvailable(network: NetworkHandle, carrierName: String?)
    fun onLost(network: NetworkHandle)
}

/** The only surface that touches the Android framework; faked in unit tests. */
interface ConnectivityFacade {
    fun requestCellular(callback: CellularCallback)
    fun unregister(callback: CellularCallback)
    fun resolve(network: NetworkHandle, domain: String): List<InetAddress>
    fun createSocket(network: NetworkHandle): Socket
    fun dnsServers(network: NetworkHandle): List<InetAddress>
}
