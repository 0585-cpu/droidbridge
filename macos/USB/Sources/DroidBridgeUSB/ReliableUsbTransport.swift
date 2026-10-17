import Foundation
import OSLog

/// One raw reader (the mux) and one dedicated raw writer. Readers only enqueue ACK
/// state; they never wait behind a full USB endpoint to send an ACK.
public final class ReliableUsbTransport: AoaByteTransport, @unchecked Sendable {
    private let raw: any AoaByteTransport
    private let condition = NSCondition()
    private var state: ReliableUsbState
    private var failure: (any Error)?
    // Reader-owned, bounded to the records in a single raw read.
    private var decoder = ReliableUsbDecoder()
    private var received: [Data] = []
    private let logger = Logger(subsystem: "io.droidbridge", category: "USBReliable")

    public convenience init(raw: any AoaByteTransport) {
        self.init(raw: raw, epoch: withUnsafeBytes(of: UUID().uuid) { Data($0) })
    }
    package init(raw: any AoaByteTransport, epoch: Data?) {
        self.raw = raw
        state = ReliableUsbState(epoch: epoch, now: ProcessInfo.processInfo.systemUptime)
        Thread.detachNewThread { [self] in writerLoop() }
    }

    public func readChunk() throws -> Data? {
        do {
            while true {
                try condition.withLock { if let failure { throw failure } }
                if !received.isEmpty { return received.removeFirst() }
                guard let bytes = try raw.readChunk() else { throw AoaError.usb("reliable USB disconnected") }
                let records = try decoder.append(bytes)
                try condition.withLock {
                    if let failure { throw failure }
                    for record in records {
                        if let payload = try state.receive(record, now: ProcessInfo.processInfo.systemUptime) {
                            received.append(payload)
                        }
                    }
                    if !records.isEmpty { condition.broadcast() }
                }
            }
        } catch { stop(error); throw error }
    }

    public func write(_ data: Data) throws {
        do {
            var offset = 0
            while offset < data.count {
                let end = min(offset + ReliableUsbRecord.maximumPayload, data.count)
                let chunk = Data(data.dropFirst(offset).prefix(end-offset))
                try condition.withLock {
                    while true {
                        if let failure { throw failure }
                        if try state.offer(chunk, now: ProcessInfo.processInfo.systemUptime) { break }
                        condition.wait()
                    }
                    condition.broadcast()
                }
                offset = end
            }
        } catch { stop(error); throw error }
    }

    private func writerLoop() {
        var reportedRetries: UInt64 = 0
        var lastReport: TimeInterval = 0
        do {
            while true {
                let record: ReliableUsbRecord? = try condition.withLock {
                    if let failure { throw failure }
                    let packet = try state.next(now: ProcessInfo.processInfo.systemUptime)
                    let now = ProcessInfo.processInfo.systemUptime
                    if state.retransmissions > reportedRetries && now-lastReport >= 5 {
                        reportedRetries = state.retransmissions; lastReport = now
                        logger.info("Reliable USB retransmission: totalRecords=\(reportedRetries)")
                    }
                    if packet == nil {
                        if let wake = state.nextWakeAt(now: now) {
                            _ = condition.wait(until: Date().addingTimeInterval(max(0.0001,wake-now)))
                        } else { condition.wait() }
                    }
                    return packet
                }
                if let record { try raw.write(record.encoded()) }
            }
        } catch { stop(error) }
    }

    public func close() { stop(AoaError.usb("reliable USB closed")) }

    private func stop(_ error: any Error) {
        let retries: UInt64? = condition.withLock {
            guard failure == nil else { return nil }
            failure = error; condition.broadcast()
            return state.retransmissions
        }
        if let retries {
            logger.info("Reliable USB stopped; retransmittedRecords=\(retries), reason=\(String(describing: error), privacy: .public)")
            // A raw close can wait for IO completion: never hold the state lock here.
            raw.close()
        }
    }
}
