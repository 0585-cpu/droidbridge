import Foundation

/// Android queues 16-KiB accessory reads. A shorter write ending on a full USB packet needs
/// a zero-length packet; otherwise a request can remain hidden until the next short write.
public enum AoaBulkWriter {
    public static func write(_ data: Data, maximumPacketSize: Int, transfer: (Data) throws -> Int) throws {
        guard (1...1024).contains(maximumPacketSize) else { throw AoaError.usb("invalid USB packet size") }
        var offset = 0
        while offset < data.count {
            let length = min(16_384, data.count - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            guard try transfer(chunk) == length else { throw AoaError.usb("incomplete USB write") }
            if length < 16_384 && length % maximumPacketSize == 0 {
                guard try transfer(Data()) == 0 else { throw AoaError.usb("invalid USB packet terminator") }
            }
            offset += length
        }
    }
}
