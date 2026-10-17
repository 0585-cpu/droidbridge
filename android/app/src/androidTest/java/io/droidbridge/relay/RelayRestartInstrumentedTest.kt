package io.droidbridge.relay

import androidx.test.ext.junit.runners.AndroidJUnit4
import io.droidbridge.protocol.OpenDestination
import io.droidbridge.security.EpochClock
import io.droidbridge.security.NonceReplayCache
import io.droidbridge.security.SessionAuthenticator
import java.net.Socket
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals

/** Real Android TCP sockets on loopback only; no USB, cellular or saved pairing access. */
@RunWith(AndroidJUnit4::class)
class RelayRestartInstrumentedTest {
    @Test fun stopStartRebindsAfterServerClosesAConnection() {
        val backend = object : RelayBackend {
            override suspend fun connect(destination: OpenDestination): Socket = error("unused")
            override suspend fun resolveDns(queryPacket: ByteArray): ByteArray = error("unused")
            override fun carrierName(): String? = null
            override fun cellularReady() = false
        }
        val server = RelayServer(SessionAuthenticator(
            { ByteArray(32) { 1 } }, NonceReplayCache(clock = EpochClock.SYSTEM), EpochClock.SYSTEM,
        ), backend)
        var port = 0
        try {
            repeat(3) {
                server.start(port)
                port = server.port
                Socket("127.0.0.1", port).use { peer ->
                    peer.soTimeout = 2000
                    // An invalid header makes the real relay close first, leaving TIME_WAIT.
                    peer.getOutputStream().write(ByteArray(64))
                    assertEquals(-1, peer.getInputStream().read())
                }
                server.stop()
            }
        } finally { server.stop() }
    }
}
