package io.droidbridge.usb

import android.content.Context
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import androidx.test.core.app.ApplicationProvider
import java.io.BufferedInputStream
import java.net.ServerSocket
import java.net.Socket
import java.nio.channels.Selector
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowPowerManager
import kotlin.test.*

@RunWith(RobolectricTestRunner::class)
@Config(sdk=[34])
class IdleWakeLockRegressionTest {
    @Test fun hostInactivityReleasesCpuAndNextResetReacquiresIt() {
        val power=ApplicationProvider.getApplicationContext<Context>().getSystemService(PowerManager::class.java)
        val pipe=ParcelFileDescriptor.createPipe()
        val resources=UsbSessionResources(pipe[0],power)
        val lock=ShadowPowerManager.getLatestWakeLock()
        ServerSocket(0).use { listener -> Socket("127.0.0.1",listener.localPort).use { host ->
            host.soTimeout=2_000
            val accessory=listener.accept()
            val bridge=AoaAccessoryBridge(accessory.getInputStream(),accessory.getOutputStream(),
                closeTransport={ accessory.close(); resources.close() }, onSessionActive=resources::setSessionActive)
            try {
                bridge.start()
                host.getOutputStream().write(AoaFrame(AoaFrame.RESET,0,payload=ByteArray(16)).encode())
                assertEquals(AoaFrame.RESET_OK,AoaFrame.read(BufferedInputStream(host.getInputStream()))!!.type)
                val type=bridge.javaClass
                val ready=type.getDeclaredField("sessionReady").apply { isAccessible=true }
                val activity=type.getDeclaredField("lastHostActivity").apply { isAccessible=true }
                val selector=type.getDeclaredField("selector").apply { isAccessible=true }.get(bridge) as Selector
                assertTrue(ready.getBoolean(bridge)); assertTrue(lock.isHeld)
                // Advance only the production inactivity input; execute the real selector timeout path.
                activity.setLong(bridge,System.nanoTime()-(ReliableUsbState.NO_PROGRESS_MS+11_000)*1_000_000)
                selector.wakeup()
                val deadline=System.nanoTime()+2_000_000_000L
                while(ready.getBoolean(bridge) && System.nanoTime()<deadline) Thread.sleep(5)
                assertFalse(ready.getBoolean(bridge),"Host session must have become inactive")
                println("idleHostSessionReady=${ready.getBoolean(bridge)} activeStreams=0 cpuWakeLockHeld=${lock.isHeld}")
                assertFalse(lock.isHeld,"Idle session should permit CPU sleep")
                host.getOutputStream().write(AoaFrame(AoaFrame.RESET,0,payload=ByteArray(16)).encode())
                assertEquals(AoaFrame.RESET_OK,AoaFrame.read(host.getInputStream())!!.type)
                assertTrue(lock.isHeld,"A new active host must keep screen-off IO runnable")
            } finally {
                bridge.close(); resources.close(); pipe[1].close()
            }
            assertFalse(lock.isHeld,"Control: explicit closure releases the same lock")
        } }
    }
}
