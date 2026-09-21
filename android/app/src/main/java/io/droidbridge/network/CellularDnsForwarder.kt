package io.droidbridge.network

import java.net.InetAddress
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.withTimeout

enum class DnsFailure { MALFORMED, NO_SERVERS, TIMEOUT, ID_MISMATCH, IO_ERROR }

class DnsFailureException(val reason: DnsFailure) : Exception("dns failure: $reason")
class DnsTimeoutException : Exception("dns timeout")

/** Sends a query over the selected cellular network, one server at a time, with TCP fallback on TC. */
interface DnsTransport {
    fun dnsServers(): List<InetAddress>
    suspend fun queryUdp(server: InetAddress, packet: ByteArray, timeoutMs: Int): ByteArray
    suspend fun queryTcp(server: InetAddress, packet: ByteArray, timeoutMs: Int): ByteArray
}

/**
 * Forwards a DNS query to the cellular resolvers: UDP first (2s per server), TCP retry when the answer
 * has the TC bit, whole operation bounded to 5s. Transaction id and QR bit are verified; names are never
 * cached or logged.
 */
class CellularDnsForwarder(private val transport: DnsTransport) {
    suspend fun query(queryPacket: ByteArray): ByteArray {
        DnsWire.validateForwardable(queryPacket)
        val expectedId = DnsWire.transactionId(queryPacket)
        val servers = transport.dnsServers()
        if (servers.isEmpty()) throw DnsFailureException(DnsFailure.NO_SERVERS)

        var sawTimeout = false
        try {
            return withTimeout(TOTAL_DEADLINE_MS.toLong()) {
                for (server in servers) {
                    val udp = try {
                        transport.queryUdp(server, queryPacket, PER_SERVER_UDP_MS)
                    } catch (e: DnsTimeoutException) {
                        sawTimeout = true; continue
                    } catch (e: java.io.IOException) {
                        continue
                    }
                    val validated = validate(udp, expectedId)
                    if (!DnsWire.isTruncated(validated)) return@withTimeout validated
                    // truncated: retry the SAME server over TCP
                    val tcp = try {
                        transport.queryTcp(server, queryPacket, PER_SERVER_TCP_MS)
                    } catch (e: DnsTimeoutException) {
                        sawTimeout = true; continue
                    } catch (e: java.io.IOException) {
                        continue
                    }
                    return@withTimeout validate(tcp, expectedId)
                }
                throw DnsFailureException(if (sawTimeout) DnsFailure.TIMEOUT else DnsFailure.IO_ERROR)
            }
        } catch (e: TimeoutCancellationException) {
            throw DnsFailureException(DnsFailure.TIMEOUT)
        }
    }

    private fun validate(response: ByteArray, expectedId: Int): ByteArray {
        if (response.size < DnsWire.MIN_PACKET || response.size > DnsWire.MAX_PACKET) throw DnsFailureException(DnsFailure.MALFORMED)
        if (!DnsWire.isResponse(response)) throw DnsFailureException(DnsFailure.MALFORMED)
        if (DnsWire.transactionId(response) != expectedId) throw DnsFailureException(DnsFailure.ID_MISMATCH)
        return response
    }

    companion object {
        const val PER_SERVER_UDP_MS = 2_000
        const val PER_SERVER_TCP_MS = 3_000
        const val TOTAL_DEADLINE_MS = 5_000
    }
}
