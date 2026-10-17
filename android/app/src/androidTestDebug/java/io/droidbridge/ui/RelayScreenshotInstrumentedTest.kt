package io.droidbridge.ui

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.util.Log
import androidx.test.core.app.ActivityScenario
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import java.io.FileOutputStream
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertTrue

/** Captures synthetic Compose UI; does not open USB, pair, or start the relay. */
@RunWith(AndroidJUnit4::class)
class RelayScreenshotInstrumentedTest {
    @Test fun captureConnectionAndSettings() {
        for (variant in listOf("setup", "ready", "settings")) {
            val context = ApplicationProvider.getApplicationContext<android.content.Context>()
            val intent = Intent(context, RelayScreenshotActivity::class.java).putExtra("variant", variant)
            ActivityScenario.launch<RelayScreenshotActivity>(intent).use { scenario ->
                InstrumentationRegistry.getInstrumentation().waitForIdleSync()
                scenario.onActivity { activity ->
                    val root = activity.window.decorView
                    assertTrue(root.width > 0 && root.height > 0)
                    val bitmap = Bitmap.createBitmap(root.width, root.height, Bitmap.Config.ARGB_8888)
                    root.draw(Canvas(bitmap))
                    val directory = File(activity.getExternalFilesDir(null), "screenshots").apply { mkdirs() }
                    val output = File(directory, "droidbridge-$variant.png")
                    FileOutputStream(output).use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                    bitmap.recycle()
                    Log.i("DroidBridgeScreenshot", output.absolutePath)
                }
            }
        }
    }
}
