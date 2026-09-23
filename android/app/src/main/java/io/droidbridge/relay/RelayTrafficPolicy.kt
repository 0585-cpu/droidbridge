package io.droidbridge.relay

import io.droidbridge.network.SocketEgressPolicy
import io.droidbridge.policy.DnsDomainFilter
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlin.math.ceil
import kotlin.math.min

data class TrafficProfile(
    val socketPolicy: SocketEgressPolicy = SocketEgressPolicy(),
    val dnsSuffixes: List<String> = emptyList(),
    val uploadBytesPerSecond: Int = 0,
    val downloadBytesPerSecond: Int = 0,
    val burstBytes: Int = 64*1024,
) {
    init {
        require(uploadBytesPerSecond >= 0 && downloadBytesPerSecond >= 0)
        require(burstBytes in 1232..4*1024*1024)
        DnsDomainFilter(dnsSuffixes)
    }
}

/** Pure monotonic bucket. A rejected take does not reserve future tokens. */
class TokenBucket(private val rate: Int, private val burst: Int, private val clock: () -> Long = System::nanoTime) {
    private var available=burst.toDouble()
    private var updated=clock()
    init { require(rate >= 0 && burst > 0) }
    @Synchronized fun tryTake(bytes: Int): Long {
        require(bytes in 0..burst)
        if (rate == 0 || bytes == 0) return 0
        val now=clock(); val elapsed=(now-updated).coerceAtLeast(0); updated=now
        available=min(burst.toDouble(),available+elapsed.toDouble()/1e9*rate)
        if (available >= bytes) { available-=bytes; return 0 }
        return ceil((bytes-available)/rate*1e9).toLong().coerceAtLeast(1)
    }
}

/** Shared across all TCP, DNS, UDP and ICMP flows of one relay run. Direction mutexes are FIFO;
 * only shaping state is held while waiting, never a socket/engine/controller lock. */
class RelayTrafficPolicy(val profile: TrafficProfile = TrafficProfile()) {
    private val uploadBucket=TokenBucket(profile.uploadBytesPerSecond,profile.burstBytes)
    private val downloadBucket=TokenBucket(profile.downloadBytesPerSecond,profile.burstBytes)
    private val uploadGate=Mutex(); private val downloadGate=Mutex()
    suspend fun upload(bytes: Int) = acquire(uploadBucket,uploadGate,bytes)
    suspend fun download(bytes: Int) = acquire(downloadBucket,downloadGate,bytes)
    suspend fun writeUpload(output: java.io.OutputStream,bytes: ByteArray) = writeShaped(output,bytes,::upload)
    suspend fun writeDownload(output: java.io.OutputStream,bytes: ByteArray) = writeShaped(output,bytes,::download)
    private suspend fun writeShaped(output: java.io.OutputStream,bytes: ByteArray,shape: suspend (Int) -> Unit) {
        var offset=0
        while(offset<bytes.size) {
            val count=min(bytes.size-offset,profile.burstBytes)
            shape(count)
            kotlinx.coroutines.runInterruptible(RelayDispatchers.socketWrites) { output.write(bytes,offset,count) }
            offset+=count
        }
        kotlinx.coroutines.runInterruptible(RelayDispatchers.socketWrites) { output.flush() }
    }
    private suspend fun acquire(bucket: TokenBucket, gate: Mutex, count: Int) {
        require(count >= 0)
        gate.withLock {
            var remaining=count
            while(remaining > 0) {
                val chunk=min(remaining,profile.burstBytes)
                while(true) { val wait=bucket.tryTake(chunk); if(wait == 0L) break; delay((wait+999999)/1000000) }
                remaining-=chunk
            }
        }
    }
}
