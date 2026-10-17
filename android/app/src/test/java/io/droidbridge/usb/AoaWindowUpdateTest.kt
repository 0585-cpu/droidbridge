package io.droidbridge.usb

import kotlin.test.*

class AoaWindowUpdateTest {
    @Test fun shortConsumptionSharesFirstDeadlineAndIdleHasNoTimer() {
        val window=AoaWindowUpdate()
        assertFalse(window.consumed(1,100))
        assertEquals(5_000_100L,window.deadlineNanos)
        assertFalse(window.consumed(200,1_000_100))
        assertEquals(5_000_100L,window.deadlineNanos)
        assertFalse(window.isDue(5_000_099));assertTrue(window.isDue(5_000_100))
        window.sent(200)
        assertNull(window.deadlineNanos)
        assertFalse(window.consumed(200,9_000_000))
        assertNull(window.deadlineNanos)
    }
    @Test fun halfWindowReplenishesCreditWithoutWaitingAndCountsDoNotTruncate() {
        val window=AoaWindowUpdate()
        val base=0x1_0000_0000L
        window.sent(base)
        assertFalse(window.consumed(base+32767,100))
        assertTrue(window.consumed(base+32768,200))
        window.sent(base+32768)
        assertFalse(window.consumed(base+32769,300))
        assertEquals(5_000_300L,window.deadlineNanos)
    }
}
