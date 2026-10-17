package io.droidbridge.usb

import java.io.Closeable
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Test
import kotlin.concurrent.thread
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UsbAccessoryRecoveryTest {
    @Test fun repeatedConnectRetainsActiveSessionUntilDetach() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        val original = fixture.sessions.single()
        fixture.controller.connect("phone")
        assertEquals(1, fixture.sessions.size, "A repeated connect must not reopen the active descriptor")
        assertEquals(1, fixture.openTimes.size)
        assertTrue(original.started)
        assertFalse(original.closed)
        assertEquals(0, fixture.heldLeases)
        fixture.controller.detached("phone")
        assertTrue(original.closed)
        fixture.scheduler.advance(30_000)
        assertEquals(1, fixture.sessions.size, "Detach must not leave a scheduled reopen")
    }

    @Test fun unexpectedCloseReopensAfterOneSecondAndTransfersWakeOwnership() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        assertEquals(1, fixture.heldLeases)
        fixture.scheduler.advance(999)
        assertEquals(1, fixture.sessions.size)
        fixture.scheduler.advance(1)
        assertEquals(2, fixture.sessions.size)
        assertTrue(fixture.sessions.last().started)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun stopBeforeRetryCancelsReopeningAndReleasesWakeLease() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        fixture.controller.close()
        fixture.scheduler.advance(30_000)
        assertEquals(1, fixture.sessions.size)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun stopDuringOpenRejectsAndClosesReturnedSession() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        val entered = CountDownLatch(1)
        val finish = CountDownLatch(1)
        fixture.beforeOpen = {
            entered.countDown()
            check(finish.await(3, TimeUnit.SECONDS))
        }
        val opener = thread { fixture.scheduler.advance(1_000) }
        try {
            assertTrue(entered.await(3, TimeUnit.SECONDS))
            val stopped = CountDownLatch(1)
            val stopper = thread { fixture.controller.close(); stopped.countDown() }
            assertTrue(stopped.await(1, TimeUnit.SECONDS), "Stop must not wait for a platform USB open")
            stopper.join()
        } finally {
            finish.countDown()
            opener.join(3_000)
        }
        assertFalse(opener.isAlive)
        assertTrue(fixture.sessions.last().closed)
        assertFalse(fixture.sessions.last().started)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun permissionLossBeforeRetryStopsWithoutOpening() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        fixture.permitted = false
        fixture.scheduler.advance(30_000)
        assertEquals(1, fixture.sessions.size)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun stopDuringPostOpenPermissionCheckImmediatelyReleasesReturnedSession() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        val checking = CountDownLatch(1)
        val finish = CountDownLatch(1)
        var checks = 0
        fixture.beforeEligibility = {
            if (++checks == 2) {
                checking.countDown()
                check(finish.await(3, TimeUnit.SECONDS))
            }
        }
        val opener = thread { fixture.scheduler.advance(1_000) }
        try {
            assertTrue(checking.await(3, TimeUnit.SECONDS))
            fixture.controller.close()
            assertTrue(fixture.sessions.last().closed, "Stop must close an already returned descriptor immediately")
            assertEquals(0, fixture.heldLeases)
        } finally {
            finish.countDown()
            opener.join(3_000)
        }
        assertFalse(fixture.sessions.last().started)
    }

    @Test fun physicalAbsenceBeforeRetryStopsWithoutOpening() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        fixture.present = false
        fixture.scheduler.advance(30_000)
        assertEquals(1, fixture.sessions.size)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun permissionLossDuringOpenClosesReturnedSession() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        fixture.beforeOpen = { fixture.permitted = false }
        fixture.scheduler.advance(30_000)
        assertTrue(fixture.sessions.last().closed)
        assertFalse(fixture.sessions.last().started)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun detachCancelsPendingAndInFlightRecovery() {
        for (duringOpen in listOf(false, true)) {
            val fixture = Fixture()
            fixture.controller.connect("phone")
            fixture.sessions.single().fail()
            if (duringOpen) fixture.beforeOpen = { fixture.controller.detached("phone") }
            else fixture.controller.detached("phone")
            fixture.scheduler.advance(30_000)
            assertTrue(fixture.sessions.all { it.closed })
            assertEquals(0, fixture.heldLeases)
        }
    }

    @Test fun staleCloseCannotRetireReplacementOrReviveStoppedSession() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        val old = fixture.sessions.single()
        old.fail()
        fixture.scheduler.advance(1_000)
        val replacement = fixture.sessions.last()
        old.notifyClosed("late old callback")
        fixture.scheduler.advance(10_000)
        assertEquals(2, fixture.sessions.size)
        assertFalse(replacement.closed)
        fixture.controller.close()
        replacement.notifyClosed("late stopped callback")
        fixture.scheduler.advance(30_000)
        assertEquals(2, fixture.sessions.size)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun canceledTimerCannotOpenAfterNewExplicitConnect() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        val canceledRetry = fixture.scheduler.tasks.single().run
        fixture.controller.close()
        fixture.controller.connect("phone")
        canceledRetry()
        assertEquals(2, fixture.sessions.size)
        assertFalse(fixture.sessions.last().closed)
    }

    @Test fun instantFailuresExhaustOneTwoFourSecondBurst() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.failOnStart = true
        fixture.sessions.single().fail()
        fixture.scheduler.advance(30_000)
        assertEquals(listOf(0L, 1_000L, 3_000L, 7_000L), fixture.openTimes)
        assertEquals(0, fixture.heldLeases)
        assertTrue(fixture.sessions.all { it.closed })
        assertTrue(fixture.statuses.last().contains("Reconnect"))
    }

    @Test fun openFailuresAlsoExhaustTheSameBurst() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.beforeOpen = { throw IOException("device busy") }
        fixture.sessions.single().fail()
        fixture.scheduler.advance(30_000)
        assertEquals(listOf(0L, 1_000L, 3_000L, 7_000L), fixture.openTimes)
        assertEquals(0, fixture.heldLeases)
    }

    @Test fun stableSessionCanRecoverFromALaterIndependentFailure() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        fixture.scheduler.advance(1_000)
        fixture.scheduler.advance(30_000)
        fixture.sessions.last().fail()
        fixture.scheduler.advance(1_000)
        assertEquals(listOf(0L, 1_000L, 32_000L), fixture.openTimes)
    }

    @Test fun slowOpenCannotPublishAfterRecoveryDeadline() {
        val fixture = Fixture()
        fixture.controller.connect("phone")
        fixture.sessions.single().fail()
        fixture.beforeOpen = { fixture.scheduler.now += 20_000 }
        fixture.scheduler.advance(1_000)
        assertTrue(fixture.sessions.last().closed)
        assertFalse(fixture.sessions.last().started)
        assertEquals(0, fixture.heldLeases)
        assertTrue(fixture.leaseTimeouts.single() <= 15_000)
    }

    private class Fixture {
        val scheduler = Scheduler()
        val sessions = mutableListOf<Session>()
        val openTimes = mutableListOf<Long>()
        val statuses = mutableListOf<String>()
        val leaseTimeouts = mutableListOf<Long>()
        var heldLeases = 0
        var permitted = true
        var present = true
        var beforeOpen: () -> Unit = {}
        var beforeEligibility: () -> Unit = {}
        var failOnStart = false
        val controller = UsbAccessoryRecovery<String>(
            eligible = { beforeEligibility(); it == "phone" && permitted && present },
            open = { _, closed ->
                openTimes += scheduler.now
                beforeOpen()
                Session(closed, failOnStart).also { sessions += it }
            },
            schedule = scheduler::schedule,
            holdRecovery = { timeout ->
                leaseTimeouts += timeout
                heldLeases++
                var closed = false
                Closeable { if (!closed) { closed = true; heldLeases-- } }
            },
            nowMillis = { scheduler.now },
            status = { statuses += it },
        )
    }

    private class Session(val notifyClosed: (String) -> Unit, val failOnStart: Boolean) : UsbAccessoryRecovery.Session {
        var started = false
        var closed = false
        override fun start() { started = true; if (failOnStart) fail() }
        override fun close() { closed = true; notifyClosed("closed") }
        fun fail() { closed = true; notifyClosed("invalid AOA version") }
    }

    private class Scheduler {
        data class Task(val at: Long, val run: () -> Unit, var canceled: Boolean = false)
        var now = 0L
        val tasks = mutableListOf<Task>()
        fun schedule(delay: Long, run: () -> Unit): Closeable {
            val task = Task(now + delay, run)
            tasks += task
            return Closeable { task.canceled = true }
        }
        fun advance(millis: Long) {
            val end = now + millis
            while (true) {
                val next = tasks.filter { !it.canceled && it.at <= end }.minByOrNull { it.at } ?: break
                tasks.remove(next)
                now = maxOf(now, next.at)
                next.run()
            }
            now = maxOf(now, end)
        }
    }
}
