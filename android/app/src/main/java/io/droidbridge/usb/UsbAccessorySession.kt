package io.droidbridge.usb

import android.hardware.usb.UsbAccessory
import android.hardware.usb.UsbManager
import java.io.BufferedInputStream
import java.io.Closeable
import java.io.FileInputStream
import java.io.FileOutputStream
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

object UsbAccessoryStatus {
    internal val mutable = MutableStateFlow("Connect USB, then select this phone in DroidBridge on the Mac.")
    val state = mutable.asStateFlow()
    fun matches(accessory: UsbAccessory) = accessory.manufacturer == "DroidBridge" && accessory.model == "DroidBridge USB"
}

/** Owned by the foreground service, never by an Activity or a Compose screen. */
class UsbAccessorySession(private val manager: UsbManager) : Closeable {
    private var accessory: UsbAccessory? = null
    private var bridge: AoaAccessoryBridge? = null

    @Synchronized fun connect(selected: UsbAccessory) {
        require(UsbAccessoryStatus.matches(selected)) { "This accessory belongs to another app." }
        check(manager.hasPermission(selected)) { "Allow DroidBridge to access USB on the phone." }
        if (selected == accessory && bridge != null) return
        close()
        val descriptor = manager.openAccessory(selected) ?: error("Cannot open USB accessory. Reconnect the cable.")
        // Buffered reads are essential: short reads directly on the USB descriptor can drop data.
        val input = BufferedInputStream(FileInputStream(descriptor.fileDescriptor), AoaFrame.MAX_PAYLOAD)
        val output = FileOutputStream(descriptor.fileDescriptor)
        accessory = selected
        lateinit var session: AoaAccessoryBridge
        session = AoaAccessoryBridge(input, output, closeTransport = {
            runCatching { descriptor.close() }
        }, onClosed = { reason ->
            synchronized(this) {
                if (bridge === session) {
                    bridge = null
                    accessory = null
                    UsbAccessoryStatus.mutable.value = reason
                }
            }
        })
        bridge = session
        UsbAccessoryStatus.mutable.value = "USB accessory connected"
        session.start()
    }

    @Synchronized fun detached(selected: UsbAccessory) {
        if (selected == accessory) close()
    }

    @Synchronized override fun close() {
        val old = bridge
        bridge = null
        accessory = null
        old?.close()
        if (old != null) UsbAccessoryStatus.mutable.value = "USB disconnected"
    }
}
