package io.droidbridge.relay

import io.droidbridge.network.SocketEgressPolicy
import io.droidbridge.policy.DnsDomainFilter
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class TrafficProfileTest {
    @Test fun `default profile leaves options filters and shaping off`() {
        val profile=TrafficProfile()
        assertNull(profile.socketPolicy.ipv4Ttl)
        assertNull(profile.socketPolicy.ipv6HopLimit)
        assertEquals(0,profile.uploadBytesPerSecond)
        assertFalse(DnsDomainFilter(profile.dnsSuffixes).blocks("update.example.test"))
    }
    @Test fun `invalid TTL rate and undersized burst rejected before opening`() {
        for(v in listOf(-1,0,256)) assertThrows(IllegalArgumentException::class.java) { SocketEgressPolicy(ipv4Ttl=v) }
        assertThrows(IllegalArgumentException::class.java) { TrafficProfile(uploadBytesPerSecond=-1) }
        assertThrows(IllegalArgumentException::class.java) { TrafficProfile(burstBytes=1231) }
    }
    @Test fun `DNS filters normalize case trailing dots and label boundaries`() {
        val filter=DnsDomainFilter(listOf("EXAMPLE.test."))
        assertTrue(filter.blocks("example.test"))
        assertTrue(filter.blocks("Update.Example.Test."))
        assertFalse(filter.blocks("notexample.test"))
        assertFalse(filter.blocks("example.test.attacker.test"))
    }
    @Test fun `shared bucket bounds aggregate bytes by monotonic refill`() {
        var now=0L
        val bucket=TokenBucket(1000,2000) { now }
        assertEquals(0,bucket.tryTake(1500))
        assertEquals(500_000_000L,bucket.tryTake(1000))
        now=500_000_000
        assertEquals(0,bucket.tryTake(1000))
        assertEquals(1_000_000_000L,bucket.tryTake(1000))
        now=Long.MAX_VALUE/2
        assertEquals(0,bucket.tryTake(2000))
        assertEquals(1_000_000L,bucket.tryTake(1))
    }
    @Test fun `shaping waiting is cancellable and default passes immediately`() = runBlocking {
        RelayTrafficPolicy().upload(65536)
        val policy=RelayTrafficPolicy(TrafficProfile(uploadBytesPerSecond=1,burstBytes=1232))
        policy.upload(1232)
        val blocked=launch { policy.upload(1232); fail("should remain throttled") }
        yield()
        withTimeout(1000) { blocked.cancelAndJoin() }
    }
    @Test fun `unlimited transfers reject a cancelled caller including zero bytes`() = runBlocking {
        val policy=RelayTrafficPolicy()
        for(upload in listOf(true,false)) for(bytes in listOf(0,1232,Int.MAX_VALUE)) {
            var rejected=false
            val caller=launch(start=CoroutineStart.UNDISPATCHED) {
                coroutineContext.cancel()
                try { if(upload) policy.upload(bytes) else policy.download(bytes) }
                catch(_: CancellationException) { rejected=true }
            }
            caller.join()
            assertTrue("cancelled transfer accepted: upload=$upload bytes=$bytes",rejected)
        }
    }
    @Test fun `unlimited directions validate counts and accept transfers larger than burst`() = runBlocking {
        val policy=RelayTrafficPolicy(TrafficProfile(burstBytes=1232))
        for(upload in listOf(true,false)) {
            try { if(upload) policy.upload(-1) else policy.download(-1); fail("negative transfer accepted") }
            catch(_: IllegalArgumentException) {}
            if(upload) { policy.upload(0); policy.upload(Int.MAX_VALUE) }
            else { policy.download(0); policy.download(Int.MAX_VALUE) }
        }
    }
    @Test fun `shaped stream writes never release more than configured burst at once`() = runBlocking {
        val profile=TrafficProfile(uploadBytesPerSecond=1000000,downloadBytesPerSecond=1000000,burstBytes=1232)
        val policy=RelayTrafficPolicy(profile)
        val chunks=mutableListOf<Int>(); val collected=java.io.ByteArrayOutputStream()
        val output=object: java.io.OutputStream() {
            override fun write(value: Int) { collected.write(value) }
            override fun write(data: ByteArray,offset: Int,length: Int) { chunks+=length; collected.write(data,offset,length) }
        }
        val packet=ByteArray(4098) {it.toByte()}
        policy.writeUpload(output,packet)
        assertArrayEquals(packet,collected.toByteArray())
        assertEquals(listOf(1232,1232,1232,402),chunks)
    }

}
