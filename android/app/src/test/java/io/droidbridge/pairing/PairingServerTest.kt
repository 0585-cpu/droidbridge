package io.droidbridge.pairing

import io.droidbridge.security.InMemoryPairingSecretStore
import io.droidbridge.ui.AppPairingFacade
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs

class PairingServerTest {
    @Test
    fun `pairing listener binds the IPv4 service address`() {
        val server = PairingServer(0)
        try {
            server.open()
            assertEquals("127.0.0.1", server.boundAddress!!.hostAddress)
            Socket("127.0.0.1", server.boundPort).close()
        } finally { server.close() }
    }

    @Test
    fun `occupied pairing port reports failure instead of crashing the app`() {
        ServerSocket().use { occupied ->
            occupied.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0))
            val facade = AppPairingFacade(
                store = InMemoryPairingSecretStore(),
                androidDisplayName = "Test Android",
                scope = CoroutineScope(Dispatchers.Unconfined + SupervisorJob()),
                serverFactory = { PairingServer(occupied.localPort) },
            )

            facade.beginPairing()

            val failed = assertIs<PairingUiState.Failed>(facade.state.value)
            assertEquals("pairing port unavailable", failed.reason)
        }
    }

    @Test
    fun `pairing listener can reopen immediately after a completed socket`() = runBlocking {
        val first = PairingServer(0)
        first.open()
        val port = first.boundPort
        val accepted = async { first.acceptOne() }
        val client = Socket(InetAddress.getByName("127.0.0.1"), port)
        val channel = accepted.await()
        channel.close()
        client.close()
        first.close()

        val second = PairingServer(port)
        try {
            second.open()
        } finally {
            second.close()
        }
    }

    @Test
    fun `cancelled pairing window cannot overwrite a newly opened window`(): Unit = runBlocking {
        val scope = CoroutineScope(Dispatchers.Default + SupervisorJob())
        val facade = AppPairingFacade(
            store = InMemoryPairingSecretStore(),
            androidDisplayName = "Test Android",
            scope = scope,
            serverFactory = { PairingServer(0) },
        )
        try {
            facade.beginPairing()
            facade.beginPairing()
            delay(100)

            assertIs<PairingUiState.Listening>(facade.state.value)
        } finally {
            facade.cancel()
            scope.cancel()
        }
    }
}
