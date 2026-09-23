import Foundation
import CAoaUSB

public struct AoaUSBDevice: Equatable, Sendable {
    public let location: String
    public let vendor: UInt16
    public let product: UInt16
    public let isAccessory: Bool
    public var id: String { "aoa:\(location)" }
    public var name: String { "Android USB \(String(format: "%04x:%04x", vendor, product))" }
}

/// Owns a libusb context/handle. Blocking IO occurs only on dedicated USB queues/threads.
public final class LibusbAccessoryTransport: AoaByteTransport, AoaControlDevice, @unchecked Sendable {
    private let condition = NSCondition()
    private var handle: OpaquePointer?
    private var closing = false
    private var operations = 0

    public static func devices(libraryPath: String) throws -> [AoaUSBDevice] {
        let context = try create(libraryPath)
        defer { db_usb_destroy(context) }
        return try enumerate(context)
    }

    public init(libraryPath: String, location: String) throws {
        let context = try Self.create(libraryPath)
        handle = context
        do {
            guard let device = try Self.enumerate(context).first(where: { $0.location == location }) else {
                throw AoaError.usb("selected phone is no longer connected")
            }
            try Self.requireSuccess(db_usb_open(context, location), "open the selected phone")
            if !device.isAccessory {
                try AoaHandshake.switchToAccessory(self, serial: location)
                db_usb_close_device(context)
                let deadline = Date().addingTimeInterval(10)
                var found = false
                repeat {
                    Thread.sleep(forTimeInterval: 0.2)
                    if try Self.enumerate(context).contains(where: { $0.location == location && $0.isAccessory }) {
                        try Self.requireSuccess(db_usb_open(context, location), "reopen the accessory")
                        found = true; break
                    }
                } while Date() < deadline
                guard found else { throw AoaError.usb("phone did not enter accessory mode; reconnect the cable") }
            }
            try Self.requireSuccess(db_usb_claim(context), "claim the accessory; close Tetrd or other USB apps and reconnect")
        } catch { close(); throw error }
    }

    deinit { close() }

    private static func create(_ path: String) throws -> OpaquePointer {
        var error = [CChar](repeating: 0, count: 256)
        guard let context = db_usb_create(path, &error, error.count) else {
            throw AoaError.usb(String(decoding: error.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return context
    }

    private static func enumerate(_ context: OpaquePointer) throws -> [AoaUSBDevice] {
        var entries = [db_usb_info](repeating: db_usb_info(), count: 64)
        let count = db_usb_list(context, &entries, Int32(entries.count))
        try requireSuccess(count, "list USB devices")
        return entries.prefix(Int(count)).map { entry in
            var entry = entry
            let location = withUnsafeBytes(of: &entry.location) { bytes in
                String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            return AoaUSBDevice(location: location, vendor: entry.vendor, product: entry.product,
                                isAccessory: entry.accessory != 0)
        }
    }
    private static func requireSuccess(_ result: Int32, _ action: String) throws {
        guard result >= 0 else { throw AoaError.usb("could not \(action) (USB error \(result))") }
    }

    private func beginIO() throws -> OpaquePointer {
        condition.lock(); defer { condition.unlock() }
        guard !closing, let handle else { throw AoaError.usb("closed") }
        operations += 1
        return handle
    }
    private func endIO() {
        condition.lock(); operations -= 1; condition.broadcast(); condition.unlock()
    }
    public func close() {
        condition.lock()
        if closing { condition.unlock(); return }
        closing = true
        while operations > 0 { condition.wait() }
        let old = handle; handle = nil
        condition.unlock()
        if let old { db_usb_destroy(old) }
    }
    public func readChunk() throws -> Data? {
        let handle = try beginIO(); defer { endIO() }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = db_usb_read(handle, &bytes, Int32(bytes.count))
        try Self.requireSuccess(count, "read USB data")
        return Data(bytes.prefix(Int(count)))
    }
    public func write(_ data: Data) throws {
        let handle = try beginIO(); defer { endIO() }
        try AoaBulkWriter.write(data, maximumPacketSize: Int(db_usb_out_packet_size(handle))) { chunk in
            var bytes = [UInt8](chunk)
            let count = bytes.withUnsafeMutableBufferPointer {
                db_usb_write(handle, $0.baseAddress, Int32($0.count))
            }
            try Self.requireSuccess(count, "write USB data")
            return Int(count)
        }
    }
    public func controlIn(request: UInt8, length: UInt16) throws -> Data {
        let handle = try beginIO(); defer { endIO() }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        let count = db_usb_control(handle, 1, request, 0, &bytes, length)
        try Self.requireSuccess(count, "query accessory support")
        return Data(bytes.prefix(Int(count)))
    }
    public func controlOut(request: UInt8, index: UInt16, data: Data) throws {
        let handle = try beginIO(); defer { endIO() }
        var bytes = [UInt8](data)
        let count = db_usb_control(handle, 0, request, index, &bytes, UInt16(bytes.count))
        try Self.requireSuccess(count, "configure accessory mode")
        guard count == bytes.count else { throw AoaError.usb("incomplete accessory setup") }
    }
}
