import SwiftUI
import DroidBridgeShared

struct DevicePickerView: View {
    let devices: [AdbDevice]
    let onSelect: (AdbDevice) -> Void

    var body: some View {
        VStack(alignment: .leading) {
            Text("Multiple devices — choose one:").font(.caption)
            ForEach(devices) { device in
                Button(device.model ?? device.serial) { onSelect(device) }
            }
        }
    }
}
