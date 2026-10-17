import Foundation

public protocol AoaControlDevice {
    func controlIn(request: UInt8, length: UInt16) throws -> Data
    func controlOut(request: UInt8, index: UInt16, data: Data) throws
}

public enum AoaHandshake {
    public static func switchToAccessory(_ device: any AoaControlDevice, serial: String) throws {
        let response = try device.controlIn(request: 51, length: 2)
        guard response.count == 2 else { throw AoaError.usb("accessory mode is unsupported") }
        let bytes = Array(response)
        let version = UInt16(bytes[0]) | UInt16(bytes[1]) << 8
        guard version == 1 || version == 2 else { throw AoaError.usb("accessory mode is unsupported") }
        let identity = ["DroidBridge", "DroidBridge USB", "Cellular USB relay", "1", "", serial]
        for (index, value) in identity.enumerated() {
            guard !value.utf8.contains(0), value.utf8.count < 256 else { throw AoaError.usb("invalid USB identity") }
            try device.controlOut(request: 52, index: UInt16(index), data: Data((value + "\0").utf8))
        }
        try device.controlOut(request: 53, index: 0, data: Data())
    }
}
