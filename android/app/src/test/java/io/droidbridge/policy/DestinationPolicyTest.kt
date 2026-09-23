package io.droidbridge.policy

import io.droidbridge.protocol.TestJson
import java.net.InetAddress
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class DestinationPolicyTest {
    private val policy = DestinationPolicy

    @Test
    fun `mixed public and private DNS answer retains only public addresses`() {
        val answers = listOf(
            InetAddress.getByName("93.184.216.34"),
            InetAddress.getByName("192.168.1.10"),
        )
        val filtered = policy.filterResolved("example.test", answers)
        assertEquals(listOf("93.184.216.34"), filtered.map { it.hostAddress!! })
    }

    @Test
    fun `all blocked DNS answers fail closed`() {
        val answers = listOf(InetAddress.getByName("127.0.0.1"), InetAddress.getByName("10.0.0.2"))
        assertFailsWith<DestinationDeniedException> {
            policy.filterResolved("rebind.test", answers)
        }
    }

    @Test
    fun `resolver order is preserved and empty answers fail closed`() {
        val answers = listOf("1.1.1.1", "9.9.9.9", "8.8.8.8").map(InetAddress::getByName)
        assertEquals(listOf("1.1.1.1", "9.9.9.9", "8.8.8.8"), policy.filterResolved("x.test", answers).map { it.hostAddress!! })
        assertFailsWith<DestinationDeniedException> { policy.filterResolved("empty.test", emptyList()) }
    }

    @Test
    fun `public IPv6 candidates are retained after dual stack extension`() {
        val v6 = InetAddress.getByName("2606:2800:220:1:248:1893:25c8:1946")
        assertEquals(PolicyResult.ALLOW, policy.evaluate(v6))
        assertEquals(listOf(v6), policy.filterResolved("v6.test", listOf(v6)))
    }

    @Test
    fun `every boundary fixture matches`() {
        val document = TestJson.loadResource("destination-policy.json")
        val results = document["results"] as Map<*, *>
        val cases = document["cases"] as List<*>
        assertEquals(53, cases.size)
        for (case in cases) {
            case as Map<*, *>
            val address = case["address"] as String
            val expected = case["expected"] as String
            val actual = policy.evaluate(InetAddress.getByName(address))
            assertEquals(expected, actual.fixtureName, address)
            assertEquals((results[expected] as Long).toInt(), actual.code, address)
        }
    }

    @Test
    fun `raw byte evaluation matches InetAddress evaluation`() {
        assertEquals(PolicyResult.DENY_PRIVATE, policy.evaluate(byteArrayOf(10, 0, 0, 1)))
        assertEquals(PolicyResult.ALLOW, policy.evaluate(byteArrayOf(93, 184.toByte(), 216.toByte(), 34)))
        assertEquals(PolicyResult.DENY_RESERVED, policy.evaluate(ByteArray(16)))
        assertEquals(PolicyResult.UNSUPPORTED_ADDRESS_FAMILY, policy.evaluate(ByteArray(15)))
    }
}
