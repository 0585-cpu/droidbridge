import SwiftUI
import DroidBridgeShared

struct DevicePickerView: View {
    let devices: [AdbDevice]
    let onSelect: (AdbDevice) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(devices) { device in
                Button { onSelect(device) } label: {
                    HStack {
                        Image(systemName: "iphone.gen3")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.model ?? "Android 휴대폰").fontWeight(.medium)
                            Text("USB 포트 \(device.transportId ?? device.serial)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }.padding(12).frame(maxWidth: .infinity)
                }.buttonStyle(.bordered)
            }
        }
    }
}
