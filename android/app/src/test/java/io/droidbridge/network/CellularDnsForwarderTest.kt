package io.droidbridge.network

import java.net.InetAddress
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse

private fun dnsQuery(txid: Int = 0x1234): ByteArray {
    val header = byteArrayOf((txid shr 8).toByte(), txid.toByte(), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0)
    val name = byteArrayOf(7) + "example".toByteArray() + byteArrayOf(3) + "com".toByteArray() + byteArrayOf(0)
    return header + name + byteArrayOf(0, 1, 0, 1)
}

private fun dnsResponse(txid: Int = 0x1234, tc: Boolean = false): ByteArray {
    val flags = if (tc) 0x8380 else 0x8180
    val header = byteArrayOf((txid shr 8).toByte(), txid.toByte(), (flags shr 8).toByte(), flags.toByte(), 0, 1, 0, 1, 0, 0, 0, 0)
    val name = byteArrayOf(7) + "example".toByteArray() + byteArrayOf(3) + "com".toByteArray() + byteArrayOf(0)
    val question = name + byteArrayOf(0, 1, 0, 1)
    val answer = byteArrayOf(0xC0.toByte(), 0x0C, 0, 1, 0, 1, 0, 0, 0x01, 0x2C, 0, 4, 93, 184.toByte(), 216.toByte(), 34)
    return header + question + answer
}

private class FakeDnsTransport(
    val udpResponses: List<ByteArray?> = emptyList(),
    val tcpResponses: List<ByteArray?> = emptyList(),
    val servers: List<InetAddress> = listOf(InetAddress.getByName("1.1.1.1")),
) : DnsTransport {
    val calls = mutableListOf<String>()
    private var udpIndex = 0
    private var tcpIndex = 0
    override fun dnsServers(): List<InetAddress> = servers
    override suspend fun queryUdp(server: InetAddress, packet: ByteArray, timeoutMs: Int): ByteArray {
        calls += "udp:${server.hostAddress}"
        return udpResponses.getOrNull(udpIndex++) ?: throw DnsTimeoutException()
    }
    override suspend fun queryTcp(server: InetAddress, packet: ByteArray, timeoutMs: Int): ByteArray {
        calls += "tcp:${server.hostAddress}"
        return tcpResponses.getOrNull(tcpIndex++) ?: throw DnsTimeoutException()
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class CellularDnsForwarderTest {
    @Test
    fun `plain udp response is returned`() = runTest {
        val transport = FakeDnsTransport(udpResponses = listOf(dnsResponse()))
        val response = CellularDnsForwarder(transport).query(dnsQuery())
        assertContentEquals(dnsResponse(), response)
        assertEquals(listOf("udp:1.1.1.1"), transport.calls)
    }

    @Test
    fun `truncated UDP response retries same server over TCP`() = runTest {
        val transport = FakeDnsTransport(udpResponses = listOf(dnsResponse(tc = true)), tcpResponses = listOf(dnsResponse(tc = false)))
        val response = CellularDnsForwarder(transport).query(dnsQuery())
        assertFalse(DnsWire.isTruncated(response))
        assertEquals(listOf("udp:1.1.1.1", "tcp:1.1.1.1"), transport.calls)
    }

    @Test
    fun `first server timeout falls through to second server`() = runTest {
        val transport = FakeDnsTransport(
            udpResponses = listOf(null, dnsResponse()),
            servers = listOf(InetAddress.getByName("1.1.1.1"), InetAddress.getByName("8.8.8.8")),
        )
        val response = CellularDnsForwarder(transport).query(dnsQuery())
        assertContentEquals(dnsResponse(), response)
        assertEquals(listOf("udp:1.1.1.1", "udp:8.8.8.8"), transport.calls)
    }

    @Test
    fun `mismatched transaction id is rejected`() = runTest {
        val transport = FakeDnsTransport(udpResponses = listOf(dnsResponse(txid = 0x9999)))
        assertFailsWith<DnsFailureException> { CellularDnsForwarder(transport).query(dnsQuery(txid = 0x1234)) }
    }

    @Test
    fun `malformed query under 12 bytes is rejected`() = runTest {
        assertFailsWith<DnsFailureException> { CellularDnsForwarder(FakeDnsTransport()).query(ByteArray(11)) }
    }

    @Test
    fun `no servers fails closed`() = runTest {
        val transport = FakeDnsTransport(servers = emptyList())
        val ex = assertFailsWith<DnsFailureException> { CellularDnsForwarder(transport).query(dnsQuery()) }
        assertEquals(DnsFailure.NO_SERVERS, ex.reason)
    }

    @Test
    fun `oversized response is rejected`() = runTest {
        val transport = FakeDnsTransport(udpResponses = listOf(ByteArray(5000)))
        assertFailsWith<DnsFailureException> { CellularDnsForwarder(transport).query(dnsQuery()) }
    }

    @Test
    fun `all servers timing out yields TIMEOUT`() = runTest {
        val transport = FakeDnsTransport(udpResponses = listOf(null, null), servers = listOf(InetAddress.getByName("1.1.1.1"), InetAddress.getByName("8.8.8.8")))
        val ex = assertFailsWith<DnsFailureException> { CellularDnsForwarder(transport).query(dnsQuery()) }
        assertEquals(DnsFailure.TIMEOUT, ex.reason)
    }
}
