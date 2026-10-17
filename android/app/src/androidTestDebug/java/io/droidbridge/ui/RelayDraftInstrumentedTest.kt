package io.droidbridge.ui

import android.accessibilityservice.AccessibilityServiceInfo
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.droidbridge.relay.TrafficProfile
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertTrue

/** Exercises the actual Compose tabs and text field with synthetic state; no relay is started. */
@RunWith(AndroidJUnit4::class)
class RelayDraftInstrumentedTest {
    @Test fun unsavedDraftSurvivesTabChangeAndReloadedProfileReplacesIt() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val automation = instrumentation.uiAutomation
        automation.serviceInfo = automation.serviceInfo.apply {
            flags = flags or AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
        }
        val context = ApplicationProvider.getApplicationContext<android.content.Context>()
        val intent = Intent(context, RelayScreenshotActivity::class.java).putExtra("variant", "settings")
        ActivityScenario.launch<RelayScreenshotActivity>(intent).use { scenario ->
            fun findTagged(current: AccessibilityNodeInfo?, tag: String): AccessibilityNodeInfo? {
                if (current == null) return null
                val id = current.viewIdResourceName
                if (id == tag || id == "io.droidbridge.android:id/$tag") return current
                for (i in 0 until current.childCount) {
                    findTagged(current.getChild(i), tag)?.let { return it }
                }
                return null
            }
            fun node(tag: String): AccessibilityNodeInfo {
                repeat(20) {
                    instrumentation.waitForIdleSync()
                    // Compose virtual nodes expose raw testTag IDs in the tree, but Android's
                    // findAccessibilityNodeInfosByViewId can miss those virtual IDs.
                    val found = findTagged(automation.rootInActiveWindow, tag)
                    if (found != null) return found
                    Thread.sleep(100)
                }
                val dump = StringBuilder()
                fun describe(current: AccessibilityNodeInfo?, depth: Int) {
                    if (current == null || depth > 12 || dump.length > 12000) return
                    dump.append(" ".repeat(depth)).append(current.viewIdResourceName)
                        .append(" | ").append(current.className)
                        .append(" | ").append(current.text).append('\n')
                    for (i in 0 until current.childCount) describe(current.getChild(i), depth + 1)
                }
                describe(automation.rootInActiveWindow, 0)
                Log.e("DroidBridgeDraftTest", "Missing $tag; accessibility tree:\n$dump")
                error("Could not find $tag in the Compose screen")
            }
            fun awaitUploadText(expected: String) {
                var observed = "<field not visible>"
                repeat(30) {
                    instrumentation.waitForIdleSync()
                    val field = findTagged(automation.rootInActiveWindow, "uploadLimitField")
                    observed = field?.text?.toString() ?: "<field not visible>"
                    if (observed.contains(expected)) return
                    Thread.sleep(100)
                }
                assertTrue(false, "Expected upload field to contain '$expected'; observed '$observed'")
            }
            val text = Bundle().apply {
                putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, "12345")
            }
            assertTrue(node("uploadLimitField").performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, text))
            assertTrue(node("connectionTab").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            node("connectionStatus")
            assertTrue(node("settingsTab").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitUploadText("12345")

            assertTrue(node("connectionTab").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            node("connectionStatus")
            scenario.onActivity { it.loadProfileForTest(TrafficProfile(uploadBytesPerSecond = 7654)) }
            assertTrue(node("settingsTab").performAction(AccessibilityNodeInfo.ACTION_CLICK))
            awaitUploadText("7654")
        }
    }
}
