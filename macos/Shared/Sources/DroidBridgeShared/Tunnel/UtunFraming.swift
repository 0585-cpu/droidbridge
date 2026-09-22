import Darwin
import Foundation

/// Encodes and decodes the four-byte address-family prefix used by macOS utun.
public enum UtunFraming {
    private static let ipv4AddressFamily = UInt32(AF_INET)

    public static func encode(_ ipv4: Data) -> Data {
        var addressFamily = ipv4AddressFamily.bigEndian
        var frame = Data(bytes: &addressFamily, count: MemoryLayout.size(ofValue: addressFamily))
        frame.append(ipv4)
        return frame
    }

    public static func decode(_ frame: Data) -> Data? {
        guard frame.count > MemoryLayout<UInt32>.size else { return nil }
        let addressFamily = frame.prefix(MemoryLayout<UInt32>.size).reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
        guard addressFamily == ipv4AddressFamily else { return nil }
        return frame.dropFirst(MemoryLayout<UInt32>.size)
    }
}
