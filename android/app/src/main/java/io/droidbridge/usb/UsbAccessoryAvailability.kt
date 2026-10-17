package io.droidbridge.usb

import android.content.Context
import android.content.IntentFilter

/** accessoryList can outlive AOA mode on vendor devices. Check the current system state too. */
data class UsbAccessoryAvailability(val connected: Boolean, val configured: Boolean, val accessory: Boolean) {
    val canOpen: Boolean get() = connected && configured && accessory
    // A configured=false event can precede configuration during AOA enumeration.
    val mustRelease: Boolean get() = !connected || !accessory

    companion object {
        const val ACTION_USB_STATE = "android.hardware.usb.action.USB_STATE"
        fun read(context: Context): UsbAccessoryAvailability {
            val state = context.registerReceiver(null, IntentFilter(ACTION_USB_STATE))
            return UsbAccessoryAvailability(
                state?.getBooleanExtra("connected", false) == true,
                state?.getBooleanExtra("configured", false) == true,
                state?.getBooleanExtra("accessory", false) == true,
            )
        }
    }
}
