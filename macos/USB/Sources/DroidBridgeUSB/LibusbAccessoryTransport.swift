import Foundation
import CAoaUSB
import OSLog

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
    private let logger = Logger(subsystem: "io.droidbridge", category: "USBTransfer")
    private let condition = NSCondition()
    private var handle: OpaquePointer?
    private var closing = false
    private var operations = 0
    private var firstFailure: String?
    private let writeTrace = AoaWriteTrace()

    public static func devices(libraryPath: String) throws -> [AoaUSBDevice] {
        try guarded("device listing") {
            let context = try create(libraryPath)
            defer { db_usb_destroy(context) }
            return try enumerate(context)
        }
    }

    private static let stall = OSAllocatedUnfairLock<String?>(initialState: nil)
    private static let stallLogger = Logger(subsystem: "io.droidbridge", category: "USBStall")
    /// A libusb call stuck on a wedged phone can hold libusb's process-wide locks, so later
    /// listings and reopens hang too and only a new process recovers. This names that call.
    public static var stalledCall: String? { stall.withLock { $0 } }

    package static func guarded<T>(_ call: String, limit: TimeInterval = 5, _ body: () throws -> T) rethrows -> T {
        let alarm = DispatchWorkItem {
            stall.withLock { $0 = call }
            stallLogger.fault("libusb \(call, privacy: .public) has not returned for \(Int(limit)) s")
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + limit, execute: alarm)
        defer {
            alarm.cancel()
            let cleared = stall.withLock { current -> Bool in
                guard current == call else { return false }
                current = nil
                return true
            }
            if cleared { stallLogger.notice("libusb \(call, privacy: .public) returned after a stall") }
        }
        return try body()
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
    private func recordFailure(_ reason: String) {
        condition.lock(); defer { condition.unlock() }
        if !closing && firstFailure == nil { firstFailure = reason }
    }
    public func close() {
        condition.lock()
        if closing { condition.unlock(); return }
        closing = true
        Self.guarded("close waiting for in-flight USB IO") { while operations > 0 { condition.wait() } }
        let old = handle; handle = nil
        condition.unlock()
        if let old { Self.guarded("USB teardown") { db_usb_destroy(old) } }
        // IO has drained, so the writer's bounded diagnostic ring is no longer mutable.
        do {
            if let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
               let path = try writeTrace.save(in: cache.appendingPathComponent("io.droidbridge/USBTrace"), failure: firstFailure) {
                logger.notice("USB OUT diagnostic trace saved: \(path.path, privacy: .public)")
            }
        } catch { logger.error("USB OUT diagnostic trace could not be saved") }
    }
    public func readChunk() throws -> Data? {
        let handle = try beginIO(); defer { endIO() }
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = db_usb_read(handle, &bytes, Int32(bytes.count))
        if count < 0 { recordFailure("USB read error \(count)") }
        try Self.requireSuccess(count, "read USB data")
        return Data(bytes.prefix(Int(count)))
    }
    public func write(_ data: Data) throws {
        let handle = try beginIO(); defer { endIO() }
        do { try writeTrace.write(data, maximumPacketSize: Int(db_usb_out_packet_size(handle))) { chunk in
            var bytes = [UInt8](chunk)
            let started = ContinuousClock.now
            let count = bytes.withUnsafeMutableBufferPointer {
                db_usb_write(handle, $0.baseAddress, Int32($0.count))
            }
            let elapsed = started.duration(to: .now)
            if count < 0 || elapsed >= .milliseconds(500) {
                let parts = elapsed.components
                let milliseconds = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
                // Diagnostics contain sizes/timing only, never tunneled data.
                logger.notice("USB OUT requested \(bytes.count) bytes, result \(count), elapsed \(milliseconds) ms")
            }
            return Int(count)
        } } catch { recordFailure(error.localizedDescription); throw error }
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
