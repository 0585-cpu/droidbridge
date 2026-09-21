package io.droidbridge.pairing

import kotlinx.coroutines.channels.Channel

/** In-memory duplex channel: the test pushes frames into [inbound] and reads what the coordinator wrote from [outbound]. */
class FakePairingChannel : PairingChannel {
    val inbound = Channel<ByteArray>(Channel.UNLIMITED)
    val outbound = Channel<ByteArray>(Channel.UNLIMITED)
    var closed = false

    override suspend fun readFrame(): ByteArray = inbound.receive()
    override suspend fun writeFrame(frame: ByteArray) { outbound.send(frame) }
    override fun close() {
        closed = true
        inbound.close()
        outbound.close()
    }
}
