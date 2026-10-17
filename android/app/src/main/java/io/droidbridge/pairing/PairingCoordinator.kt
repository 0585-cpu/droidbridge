package io.droidbridge.pairing

import io.droidbridge.security.PairingSecretStore
import java.security.SecureRandom
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout

sealed interface PairingUiState {
    data object Closed : PairingUiState
    data class Listening(val expiresInSeconds: Long) : PairingUiState
    data class AwaitingApproval(val sas: String, val macDisplayName: String) : PairingUiState
    data class Completed(val macDisplayName: String) : PairingUiState
    data class Failed(val reason: String) : PairingUiState
}

/**
 * Runs one pairing attempt inside a bounded window. The secret is persisted only after the Mac's proof
 * verifies AND the local user approved; on any other exit the derived secret is wiped.
 */
class PairingCoordinator(
    private val store: PairingSecretStore,
    private val acceptChannel: suspend () -> PairingChannel,
    private val scope: CoroutineScope,
    private val androidPeerId: String,
    private val androidDisplayName: String,
    private val random: SecureRandom = SecureRandom(),
    private val onWindowClosed: () -> Unit = {},
) {
    private val _state = MutableStateFlow<PairingUiState>(PairingUiState.Closed)
    val state: StateFlow<PairingUiState> = _state

    private var job: Job? = null
    private var decision: CompletableDeferred<Boolean>? = null

    fun openWindow(duration: Duration = 60.seconds): Job {
        job?.let { if (it.isActive) return it }
        _state.value = PairingUiState.Listening(duration.inWholeSeconds)
        val newJob = scope.launch {
            var channel: PairingChannel? = null
            try {
                withTimeout(duration) {
                    channel = acceptChannel()
                    runExchange(channel!!)
                }
            } catch (e: TimeoutCancellationException) {
                _state.value = PairingUiState.Closed
            } catch (e: PairingException) {
                _state.value = PairingUiState.Failed(e.message ?: "pairing failed")
            } catch (e: java.io.IOException) {
                currentCoroutineContext().ensureActive()
                _state.value = PairingUiState.Failed("connection error")
            } finally {
                channel?.close()
                decision = null
                onWindowClosed()
            }
        }
        job = newJob
        return newJob
    }

    fun approve() { decision?.complete(true) }
    fun reject() { decision?.complete(false) }

    @Synchronized fun cancel() {
        job?.cancel()
        job = null
        _state.value = PairingUiState.Closed
    }

    private suspend fun runExchange(channel: PairingChannel) {
        val macHello = PairingHello.parse(PairingFrames.readJson(channel))
        if (macHello.role != "mac") throw PairingException("expected mac hello")

        val keyPair = PairingProtocol.generateKeyPair(random)
        val nonce = ByteArray(32).also { random.nextBytes(it) }
        val androidHello = PairingHello("android", androidPeerId, androidDisplayName, PairingProtocol.encodePublicKey(keyPair.public), nonce)
        PairingFrames.writeJson(channel, androidHello.canonicalJson())

        val transcript = PairingTranscript.create(macHello, androidHello)
        val result = PairingProtocol.derive(keyPair.private, PairingProtocol.decodePublicKey(macHello.publicKey), transcript)
        try {
            val userDecision = CompletableDeferred<Boolean>().also { decision = it }
            _state.value = PairingUiState.AwaitingApproval(result.sas, macHello.displayName)

            val approved = userDecision.await()
            if (!approved) {
                PairingFrames.writeJson(channel, PairingApproval(transcript.sessionId, false, null).toJson())
                _state.value = PairingUiState.Closed
                return
            }

            val macApproval = PairingApproval.parse(PairingFrames.readJson(channel))
            val macProofValid = macApproval.approved && macApproval.sessionId == transcript.sessionId &&
                macApproval.proof != null && PairingProtocol.verifyApprovalProof(result.secret, "mac", transcript, macApproval.proof)
            if (!macProofValid) {
                PairingFrames.writeJson(channel, PairingApproval(transcript.sessionId, false, null).toJson())
                throw PairingException("mac did not approve")
            }

            val context = currentCoroutineContext()
            synchronized(this) {
                // Forget clears storage after cancel returns. A commit that already owns this
                // monitor finishes first; a cancelled worker can never persist afterwards.
                context.ensureActive()
                store.replace(PairedPeer(macHello.peerId, macHello.displayName, result.secret.copyOf()))
            }
            val proof = PairingProtocol.approvalProof(result.secret, "android", transcript)
            PairingFrames.writeJson(channel, PairingApproval(transcript.sessionId, true, proof).toJson())
            synchronized(this) { context.ensureActive(); _state.value = PairingUiState.Completed(macHello.displayName) }
        } finally {
            result.secret.fill(0)
        }
    }
}
