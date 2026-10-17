import Foundation
import CryptoKit

/// Transport-local, payload-free diagnostics. Only the USB writer mutates the trace.
public final class AoaWriteTrace {
    public struct Suffix: Codable, Equatable {
        public let removedPrefix: Int
        public let length: Int
        public let sha256: String
    }
    public struct Record: Codable, Equatable {
        public let ordinal: UInt64
        public let frame: UInt64
        public let frameType: Int
        public let frameLength: Int
        public let chunkOffset: Int
        public let requested: Int
        public let returned: Int
        public let endOffset: UInt64
        public let uptimeNanoseconds: UInt64
        public let sha256: String
        public let prefix16Sha256: String
        public let suffixes: [Suffix]
    }
    public struct Snapshot: Codable {
        public let createdAt: Date
        public let createdUptimeNanoseconds: UInt64
        public let frames: UInt64
        public let calls: UInt64
        public let bytesReported: UInt64
        public let maximumPacketSize: Int?
        public let first: Record?
        public let recent: [Record]
        public let failure: String?
    }

    private struct StoredSuffix {
        let offset: Int
        let hash: SHA256.Digest
    }
    private struct Stored {
        let ordinal: UInt64
        let frame: UInt64
        let frameType: Int
        let frameLength: Int
        let chunkOffset: Int
        let requested: Int
        let returned: Int
        let endOffset: UInt64
        let uptimeNanoseconds: UInt64
        let hash: SHA256.Digest
        let prefix: SHA256.Digest
        let suffixes: [StoredSuffix]

        var record: Record {
            Record(ordinal: ordinal, frame: frame, frameType: frameType, frameLength: frameLength,
                   chunkOffset: chunkOffset, requested: requested, returned: returned, endOffset: endOffset,
                   uptimeNanoseconds: uptimeNanoseconds, sha256: Self.hex(hash), prefix16Sha256: Self.hex(prefix),
                   suffixes: suffixes.map { Suffix(removedPrefix: $0.offset, length: requested - $0.offset,
                                                  sha256: Self.hex($0.hash)) })
        }
        private static func hex(_ digest: SHA256.Digest) -> String {
            let digits = Array("0123456789abcdef".utf8)
            return String(decoding: digest.flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
        }
    }

    private static let capacity = 8192
    private static let storageLock = NSLock()
    private let createdAt = Date()
    private let createdUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
    private var frames: UInt64 = 0
    private var calls: UInt64 = 0
    private var bytesReported: UInt64 = 0
    private var maximumPacketSize: Int?
    private var first: Stored?
    private var entries = [Stored?](repeating: nil, count: capacity)
    private var next = 0

    public init() {}

    /// Matches the production writer's transfer/error contract, without retaining transmitted bytes.
    public func write(_ frame: Data, maximumPacketSize: Int, transfer: (Data) -> Int) throws {
        frames += 1
        self.maximumPacketSize = maximumPacketSize
        let frameType = frame.count >= 6 ? Int(frame[frame.startIndex + 5]) : -1
        var offset = 0
        try AoaBulkWriter.write(frame, maximumPacketSize: maximumPacketSize) { chunk in
            // Fingerprint exactly the immutable bytes offered to native IO, before the call.
            let hash = SHA256.hash(data: chunk)
            let prefix = SHA256.hash(data: chunk.prefix(16))
            var suffixes: [StoredSuffix] = []
            let suffixCount = min(32, max(0, (chunk.count - 1) / maximumPacketSize))
            suffixes.reserveCapacity(suffixCount)
            for index in 0..<suffixCount {
                let removed = (index + 1) * maximumPacketSize
                suffixes.append(StoredSuffix(offset: removed, hash: SHA256.hash(data: chunk.dropFirst(removed))))
            }
            let count = transfer(chunk)
            calls += 1
            if count > 0 { bytesReported += UInt64(count) }
            let entry = Stored(ordinal: calls, frame: frames, frameType: frameType, frameLength: frame.count,
                               chunkOffset: offset, requested: chunk.count, returned: count, endOffset: bytesReported,
                               uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
                               hash: hash, prefix: prefix, suffixes: suffixes)
            if first == nil { first = entry }
            entries[next] = entry
            next = (next + 1) % Self.capacity
            offset += chunk.count
            guard count >= 0 else { throw AoaError.usb("could not write USB data (USB error \(count))") }
            return count
        }
    }

    /// Call on the writer, or after all transport IO has drained during close.
    public func snapshot(failure: String? = nil) -> Snapshot {
        let count = min(Int(calls), Self.capacity)
        let start = calls < UInt64(Self.capacity) ? 0 : next
        let recent = (0..<count).compactMap { entries[(start + $0) % Self.capacity]?.record }
        return Snapshot(createdAt: createdAt, createdUptimeNanoseconds: createdUptimeNanoseconds,
                        frames: frames, calls: calls, bytesReported: bytesReported,
                        maximumPacketSize: maximumPacketSize, first: first?.record, recent: recent,
                        failure: failure ?? recent.first(where: { $0.returned < 0 }).map { "USB write error \($0.returned)" })
    }

    /// Bounded diagnostic files; never removes files outside this UUID-named namespace.
    public func save(in directory: URL, failure: String? = nil) throws -> URL? {
        guard calls > 0 || failure != nil else { return nil }
        let snapshot = snapshot(failure: failure)
        // Preserve failures from sessions that actually sent bytes separately. Immediate
        // zero-byte reopen failures must not rotate away the original failure's history.
        let directory = snapshot.failure != nil && bytesReported > 0
            ? directory.appendingPathComponent("failures", isDirectory: true) : directory
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        return try Self.storageLock.withLock {
            let manager = FileManager.default
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let prefix = "usb-out-trace-"
            let owned = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                .filter { url in
                    let name = url.deletingPathExtension().lastPathComponent
                    let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    return url.pathExtension == "json" && name.hasPrefix(prefix)
                        && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
                        && attributes?.isRegularFile == true && attributes?.isSymbolicLink == false
                }
                .sorted { left, right in
                    let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return a < b
                }
            for old in owned.prefix(max(0, owned.count - 3)) { try manager.removeItem(at: old) }
            let destination = directory.appendingPathComponent("\(prefix)\(UUID()).json")
            try data.write(to: destination, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        }
    }
}
