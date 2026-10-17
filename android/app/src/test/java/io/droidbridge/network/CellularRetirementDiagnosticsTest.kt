package io.droidbridge.network

import org.junit.Assert.*
import org.junit.Test
import java.io.Closeable
import java.net.InetAddress
import java.net.Socket

class CellularRetirementDiagnosticsTest {
    private class Facade : ConnectivityFacade {
        override fun requestCellular(callback: CellularCallback) {}
        override fun unregister(callback: CellularCallback) {}
        override fun resolve(network: NetworkHandle,domain: String)=emptyList<InetAddress>()
        override fun dnsServers(network: NetworkHandle)=emptyList<InetAddress>()
        override fun createSocket(network: NetworkHandle)=Socket()
    }
    @Test fun `retirement reports cause generation and owned count once per invalidation`() {
        val events=mutableListOf<CellularRetirementEvent>()
        val controller=CellularNetworkController(Facade(),events::add)
        val first=object: NetworkHandle {}; val second=object: NetworkHandle {}; var closed=0
        controller.start(); controller.onAvailable(first,"not included")
        controller.track(controller.snapshot(),Closeable { closed++ })
        controller.track(controller.snapshot(),Closeable { closed++ })
        controller.onChanged(second); controller.onLost(second) // stale callbacks never retire this generation
        controller.onChanged(first)
        controller.onAvailable(first,null) // same network leaves the generation intact
        controller.track(controller.snapshot(),Closeable { closed++ })
        controller.onAvailable(second,null)
        controller.track(controller.snapshot(),Closeable { closed++ })
        controller.onLost(second)
        controller.stop()
        assertEquals(4,closed)
        assertEquals(listOf(
            CellularRetirementEvent(CellularRetirementReason.AVAILABLE,1,0),
            CellularRetirementEvent(CellularRetirementReason.LINK_PROPERTIES_CHANGED,2,2),
            CellularRetirementEvent(CellularRetirementReason.REPLACED,3,1),
            CellularRetirementEvent(CellularRetirementReason.LOST,4,1),
            CellularRetirementEvent(CellularRetirementReason.STOP,5,0),
        ),events)
    }
    @Test fun `diagnostic observer failure cannot prevent socket retirement`() {
        var events=0; var closed=false
        val controller=CellularNetworkController(Facade()) { events++; throw IllegalStateException("observer failure") }
        controller.start(); controller.onAvailable(object: NetworkHandle {},null)
        controller.track(controller.snapshot(),Closeable { closed=true })
        controller.stop()
        assertTrue(closed); assertEquals(2,events); assertEquals(2,controller.currentGeneration())
    }
}
