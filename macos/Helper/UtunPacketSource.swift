import DroidBridgeShared
import Foundation

/// Serializes blocking utun reads away from the XPC and engine queues.
final class UtunPacketSource: PacketSource, @unchecked Sendable {
    private let device: UtunDevice
    private let readQueue = DispatchQueue(label: "io.droidbridge.utun.read")

    init(_ device: UtunDevice) {
        self.device = device
    }

    func read(_ handler: @escaping @Sendable ([Data]) -> Void) {
        readQueue.async {
            if let packet = self.device.read() {
                handler([packet])
            } else {
                handler([])
            }
        }
    }

    func write(_ packets: [Data]) {
        for packet in packets {
            guard device.write(packet) else { return }
        }
    }
}
