package io.droidbridge.network

import io.droidbridge.policy.DnsDomainFilter
import org.junit.Assert.*
import org.junit.Test
import kotlinx.coroutines.runBlocking
import java.net.InetAddress

class DnsPolicyTest {
    private fun query(name: String,type: Int): ByteArray = byteArrayOf(1,2,1,0,0,1,0,0,0,0,0,0)+name.split('.').flatMap { listOf(it.length.toByte())+it.toByteArray().toList() }.toByteArray()+byteArrayOf(0,0,type.toByte(),0,1)
    private class Transport : DnsTransport {
        var calls=0
        override fun dnsServers()=listOf(InetAddress.getByName("8.8.8.8"))
        override suspend fun queryUdp(server: InetAddress,packet: ByteArray,timeoutMs: Int): ByteArray { calls++; return packet.clone().also { it[2]=0x81.toByte(); it[3]=0x80.toByte() } }
        override suspend fun queryTcp(server: InetAddress,packet: ByteArray,timeoutMs: Int)=error("unexpected fallback")
    }
    @Test fun `blocked A and AAAA return NXDOMAIN and never call transport`()=runBlocking {
        val transport=Transport(); val forwarder=CellularDnsForwarder(transport,DnsDomainFilter(listOf("example.test")))
        for(type in listOf(1,28)) {
            val response=forwarder.query(query("update.example.test",type))
            assertEquals(3,response[3].toInt() and 15)
            assertTrue(DnsWire.isResponse(response))
            assertEquals(0,transport.calls)
        }
        forwarder.query(query("notexample.test",1)); assertEquals(1,transport.calls)
    }
    @Test fun `unavailable IPv6 returns empty AAAA answer while A still forwards`()=runBlocking {
        val transport=Transport(); val forwarder=CellularDnsForwarder(transport,ipv6Available={false})
        val answer=forwarder.query(query("example.test",28))
        assertEquals(0,answer[3].toInt() and 15); assertEquals(0,answer[7].toInt()); assertEquals(0,transport.calls)
        forwarder.query(query("example.test",1)); assertEquals(1,transport.calls)
    }
    @Test fun `malformed compression loop is rejected with finite parsing`()=runBlocking {
        val transport=Transport()
        val packet=byteArrayOf(1,2,1,0,0,1,0,0,0,0,0,0,-64,12,0,1,0,1)
        try { CellularDnsForwarder(transport,DnsDomainFilter(listOf("example.test"))).query(packet); fail("loop accepted") } catch(_: DnsFailureException) {}
        assertEquals(0,transport.calls)
    }
    @Test fun `IPv4 A answer survives incidental AAAA additional glue`()=runBlocking {
        val request=query("example.test",1)
        val response=request.clone().also { it[2]=0x81.toByte(); it[3]=0x80.toByte(); it[7]=1; it[11]=1 } +
            byteArrayOf(-64,12,0,1,0,1,0,0,0,60,0,4,8,8,8,8) +
            byteArrayOf(-64,12,0,28,0,1,0,0,0,60,0,16) + InetAddress.getByName("2606:4700::1111").address
        val transport=object: DnsTransport {
            override fun dnsServers()=listOf(InetAddress.getByName("8.8.8.8"))
            override suspend fun queryUdp(server: InetAddress,packet: ByteArray,timeoutMs: Int)=response
            override suspend fun queryTcp(server: InetAddress,packet: ByteArray,timeoutMs: Int)=error("unexpected TCP")
        }
        val answer=CellularDnsForwarder(transport,ipv6Available={false}).query(request)
        assertArrayEquals(response,answer)
    }

}
