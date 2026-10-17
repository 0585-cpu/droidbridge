package io.droidbridge.relay

import io.droidbridge.protocol.*
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test
import java.net.*

class UdpAssociationExitDiagnosticsTest {
    private val loopback=InetAddress.getByName("127.0.0.1")
    @Test fun `association emits one endpoint free reason for EOF malformed input IO idle and cancellation`() = runBlocking {
        for(expected in listOf(UdpAssociationExitReason.EOF,UdpAssociationExitReason.PROTOCOL,UdpAssociationExitReason.IO,UdpAssociationExitReason.IDLE,UdpAssociationExitReason.CANCELLED)) {
            val events=java.util.concurrent.CopyOnWriteArrayList<UdpAssociationExitReason>()
            DatagramSocket(0,loopback).use { remote -> DatagramSocket(0,loopback).use { destination ->
                destination.soTimeout=2000
                ServerSocket(0,1,loopback).use { listener -> Socket(loopback,listener.localPort).use { client ->
                    val peer=listener.accept()
                    val task=launch(Dispatchers.IO) {
                        UdpAssociationRelaySession(peer,remote,UdpAssociationOpen(4,30),RelayTrafficPolicy(),{},{},{_,_->},
                            idleNanos=if(expected==UdpAssociationExitReason.IDLE) 50_000_000 else 30_000_000_000,onExit=events::add).run()
                    }
                    try {
                        if(expected!=UdpAssociationExitReason.IDLE) {
                            // Observe a forwarded packet before manipulating an active session's lifecycle.
                            client.getOutputStream().write(AssociationDatagramCodec.encode(RawAssociationDatagram(byteArrayOf(1),0,0,4,loopback.address,destination.localPort)))
                            withContext(Dispatchers.IO) { destination.receive(DatagramPacket(ByteArray(8),8)) }
                        }
                        when(expected) {
                            UdpAssociationExitReason.EOF -> client.shutdownOutput()
                            UdpAssociationExitReason.PROTOCOL -> { client.getOutputStream().write(byteArrayOf(0)); client.shutdownOutput() }
                            UdpAssociationExitReason.IO -> remote.close()
                            UdpAssociationExitReason.IDLE -> Unit
                            UdpAssociationExitReason.CANCELLED -> task.cancel()
                            else -> error("unexpected test case")
                        }
                        withTimeout(1500) { task.join() }
                        assertTrue(remote.isClosed); assertTrue(peer.isClosed)
                        assertEquals(listOf(expected),events)
                    } finally { client.close(); remote.close(); task.cancel(); withTimeout(1500) { task.join() } }
                } }
            } }
        }
    }
}
