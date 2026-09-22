package io.droidbridge.pairing

import io.droidbridge.security.InMemoryPairingSecretStore
import java.io.IOException
import java.security.KeyPair
import java.security.SecureRandom
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertIs
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

class Party(val keyPair: KeyPair, val hello: PairingHello) {
    val privateKey get() = keyPair.private
}

fun deterministicParty(seed: Long, role: String = if (seed % 2 == 1L) "mac" else "android"): Party {
    val random = SecureRandom.getInstance("SHA1PRNG").also { it.setSeed(seed) }
    val keyPair = PairingProtocol.generateKeyPair(random)
    val nonce = ByteArray(32).also { random.nextBytes(it) }
    val hello = PairingHello(
        role = role, peerId = "peer-$seed", displayName = "Device $seed",
        publicKey = PairingProtocol.encodePublicKey(keyPair.public), nonce = nonce,
    )
    return Party(keyPair, hello)
}

@OptIn(ExperimentalCoroutinesApi::class)
class PairingProtocolTest {
    @Test
    fun `both roles derive same secret and six digit SAS`() {
        val mac = deterministicParty(seed = 1)
        val phone = deterministicParty(seed = 2)
        val transcript = PairingTranscript.create(mac.hello, phone.hello)

        val macResult = PairingProtocol.derive(mac.privateKey, PairingProtocol.decodePublicKey(phone.hello.publicKey), transcript)
        val phoneResult = PairingProtocol.derive(phone.privateKey, PairingProtocol.decodePublicKey(mac.hello.publicKey), transcript)

        assertContentEquals(macResult.secret, phoneResult.secret)
        assertEquals(32, macResult.secret.size)
        assertEquals(macResult.sas, phoneResult.sas)
        assertTrue(macResult.sas.matches(Regex("[0-9]{6}")))
    }

    @Test
    fun `hello canonical json round trips and is key sorted`() {
        val hello = deterministicParty(1).hello
        val json = hello.canonicalJson()
        assertTrue(json.startsWith("{\"displayName\":"))
        assertEquals(hello, PairingHello.parse(json))
        assertFailsWith<PairingException> { PairingHello.parse(json.replace("\"version\":1", "\"version\":2")) }
        assertFailsWith<PairingException> { PairingHello.parse(json.replace("\"role\":\"mac\"", "\"role\":\"pc\"")) }
    }

    @Test
    fun `transcript tampering changes sas and breaks approval proof`() {
        val mac = deterministicParty(1)
        val phone = deterministicParty(2)
        val transcript = PairingTranscript.create(mac.hello, phone.hello)
        val tampered = PairingTranscript.create(mac.hello.copy(displayName = "Evil"), phone.hello)
        val macKey = PairingProtocol.decodePublicKey(mac.hello.publicKey)
        val good = PairingProtocol.derive(phone.privateKey, macKey, transcript)
        val bad = PairingProtocol.derive(phone.privateKey, macKey, tampered)
        // salt is macNonce||androidNonce, so a display-name tamper leaves the ECDH/HKDF secret unchanged
        // but changes the SAS and the transcript hash the approval proof is bound to.
        assertTrue(good.secret.contentEquals(bad.secret))
        assertFalse(transcript.sas == tampered.sas)
        val proof = PairingProtocol.approvalProof(good.secret, "mac", transcript)
        assertTrue(PairingProtocol.verifyApprovalProof(good.secret, "mac", transcript, proof))
        assertFalse(PairingProtocol.verifyApprovalProof(good.secret, "mac", tampered, proof))
        assertFalse(PairingProtocol.verifyApprovalProof(good.secret, "android", transcript, proof))
    }

    @Test
    fun `invalid public keys are rejected`() {
        val valid = deterministicParty(1).hello.publicKey
        assertFailsWith<PairingException> { PairingProtocol.decodePublicKey(valid.copyOf(64)) }
        assertFailsWith<PairingException> { PairingProtocol.decodePublicKey(valid.copyOf().also { it[0] = 0x02 }) }
        assertFailsWith<PairingException> { PairingProtocol.decodePublicKey(valid.copyOf().also { it[10] = (it[10] + 1).toByte() }) }
        assertFailsWith<PairingException> { PairingProtocol.decodePublicKey(ByteArray(65).also { it[0] = 0x04 }) }
    }

    @Test
    fun `frames above 8192 bytes are rejected`() = runTest {
        val channel = FakePairingChannel()
        channel.inbound.send(ByteArray(8193))
        assertFailsWith<PairingException> { PairingFrames.readJson(channel) }
    }

    // --- coordinator -------------------------------------------------------
    //
    // The coordinator runs its exchange in a launched coroutine doing real channel I/O, so these tests
    // use a real dispatcher and synchronize through the channels (outbound.receive blocks until the
    // coordinator writes) and Job.join(), rather than virtual time. State assertions wait via
    // state.first { } so they never race the transition.

    private class Harness(scope: CoroutineScope) {
        val store = InMemoryPairingSecretStore()
        val channel = FakePairingChannel()
        val accepted = CompletableDeferred<PairingChannel>()
        val coordinator = PairingCoordinator(
            store, { accepted.await() }, scope, androidPeerId = "android-1", androidDisplayName = "Pixel",
        )
        val mac = deterministicParty(1)

        suspend fun connectAndHello() {
            accepted.complete(channel)
            channel.inbound.send(mac.hello.canonicalJson().toByteArray())
        }

        suspend fun androidHello(): PairingHello = PairingHello.parse(String(channel.outbound.receive(), Charsets.UTF_8))
        suspend fun readApproval(): PairingApproval = PairingApproval.parse(String(channel.outbound.receive(), Charsets.UTF_8))
        suspend fun awaitApproval(): PairingUiState.AwaitingApproval =
            coordinator.state.first { it is PairingUiState.AwaitingApproval } as PairingUiState.AwaitingApproval
    }

    private fun coordinatorTest(body: suspend CoroutineScope.(CoroutineScope) -> Unit) = runBlocking {
        val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
        try {
            withTimeout(10.seconds) { body(scope) }
        } finally {
            scope.cancel()
        }
    }

    @Test
    fun `pairing window expires without persisting secret`() = coordinatorTest { scope ->
        val h = Harness(scope)
        val job = h.coordinator.openWindow(200.milliseconds) // accepted never completes -> times out
        assertIs<PairingUiState.Listening>(h.coordinator.state.value)
        job.join()
        assertEquals(PairingUiState.Closed, h.coordinator.state.value)
        assertNull(h.store.load())
    }

    @Test
    fun `cancelling a socket accept cannot publish a connection failure`() = coordinatorTest { scope ->
        val entered = CompletableDeferred<Unit>()
        val coordinator = PairingCoordinator(
            store = InMemoryPairingSecretStore(),
            acceptChannel = {
                entered.complete(Unit)
                try {
                    awaitCancellation()
                } finally {
                    throw IOException("listener closed")
                }
            },
            scope = scope,
            androidPeerId = "android-1",
            androidDisplayName = "Pixel",
        )
        val job = coordinator.openWindow(5.seconds)
        entered.await()

        coordinator.cancel()
        job.join()

        assertEquals(PairingUiState.Closed, coordinator.state.value)
    }

    @Test
    fun `full pairing persists exactly one peer after both approvals`() = coordinatorTest { scope ->
        val h = Harness(scope)
        h.store.replace(PairedPeer("old-mac", "Old", ByteArray(32) { 9 }))
        val job = h.coordinator.openWindow(5.seconds)
        h.connectAndHello()
        val androidHello = h.androidHello()
        assertEquals("android", androidHello.role)
        val transcript = PairingTranscript.create(h.mac.hello, androidHello)
        val macSide = PairingProtocol.derive(h.mac.privateKey, PairingProtocol.decodePublicKey(androidHello.publicKey), transcript)
        val awaiting = h.awaitApproval()
        assertEquals(macSide.sas, awaiting.sas)
        assertEquals("Device 1", awaiting.macDisplayName)
        assertEquals("old-mac", assertNotNull(h.store.load()).peerId) // nothing replaced yet

        val macApproval = PairingApproval(transcript.sessionId, true, PairingProtocol.approvalProof(macSide.secret, "mac", transcript))
        h.channel.inbound.send(macApproval.toJson().toByteArray())
        h.coordinator.approve()
        val approval = h.readApproval()
        job.join()

        assertTrue(approval.approved)
        assertTrue(PairingProtocol.verifyApprovalProof(macSide.secret, "android", transcript, approval.proof!!))
        assertEquals(PairingUiState.Completed("Device 1"), h.coordinator.state.value)
        val stored = assertNotNull(h.store.load())
        assertEquals("peer-1", stored.peerId)
        assertContentEquals(macSide.secret, stored.secret)
        assertTrue(h.channel.closed)
    }

    @Test
    fun `android rejection sends approved false and stores nothing`() = coordinatorTest { scope ->
        val h = Harness(scope)
        val job = h.coordinator.openWindow(5.seconds)
        h.connectAndHello()
        h.androidHello()
        h.awaitApproval()
        h.coordinator.reject()
        val approval = h.readApproval()
        job.join()
        assertFalse(approval.approved)
        assertNull(approval.proof)
        assertEquals(PairingUiState.Closed, h.coordinator.state.value)
        assertNull(h.store.load())
        assertTrue(h.channel.closed)
    }

    @Test
    fun `mac rejection or bad proof stores nothing even after android approval`() = coordinatorTest { scope ->
        for (badProof in listOf(false, true)) {
            val h = Harness(scope)
            val job = h.coordinator.openWindow(5.seconds)
            h.connectAndHello()
            val androidHello = h.androidHello()
            h.awaitApproval()
            val transcript = PairingTranscript.create(h.mac.hello, androidHello)
            val proof = if (badProof) ByteArray(32) else null
            h.channel.inbound.send(PairingApproval(transcript.sessionId, badProof, proof).toJson().toByteArray())
            h.coordinator.approve()
            h.readApproval() // coordinator sends a rejection frame before failing
            job.join()
            assertIs<PairingUiState.Failed>(h.coordinator.state.value)
            assertNull(h.store.load())
            assertTrue(h.channel.closed)
        }
    }

    @Test
    fun `malformed mac hello fails closed`() = coordinatorTest { scope ->
        val h = Harness(scope)
        val job = h.coordinator.openWindow(5.seconds)
        h.accepted.complete(h.channel)
        h.channel.inbound.send("{\"version\":1}".toByteArray())
        job.join()
        assertIs<PairingUiState.Failed>(h.coordinator.state.value)
        assertNull(h.store.load())
        assertTrue(h.channel.closed)
    }
}
