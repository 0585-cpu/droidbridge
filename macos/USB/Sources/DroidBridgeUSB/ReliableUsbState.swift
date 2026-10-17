import Foundation

/// Caller serializes access. IO never runs under this state machine's lock.
package struct ReliableUsbState {
    // Samsung's freezer can stop the phone app for tens of seconds (seen: ~45 s) with USB still
    // attached. A shorter deadline turns that pause into a torn-down session and dropped flows.
    package static let noProgressSeconds: TimeInterval = 60
    private struct Pending {
        let sequence: UInt64
        let payload: Data
        var retryAt: TimeInterval?
        var retryDelay: TimeInterval = 0.5
    }
    private let host: Bool
    private var epoch: Data?
    private let started: TimeInterval
    private var helloSent: TimeInterval?
    private var helloReply = false
    private var ackAt: TimeInterval?
    private var ackRecords = 0
    private var ready = false
    private var sent: UInt64 = 0
    private var emitted: UInt64 = 0
    private var acknowledged: UInt64 = 0
    private var received: UInt64 = 0
    private var progress: TimeInterval
    private var pending: [Pending] = []
    package private(set) var retransmissions: UInt64 = 0

    package init(epoch: Data?, now: TimeInterval) {
        self.epoch = epoch; host = epoch != nil; started = now; progress = now
    }

    package mutating func offer(_ bytes: Data, now: TimeInterval) throws -> Bool {
        guard !bytes.isEmpty, bytes.count <= ReliableUsbRecord.maximumPayload else {
            throw AoaError.protocolViolation("invalid reliable USB payload")
        }
        guard ready, pending.count < 32 else { return false }
        guard sent < UInt64(Int64.max) else { throw AoaError.protocolViolation("USB sequence exhausted") }
        if pending.isEmpty { progress = now }
        sent += 1; pending.append(Pending(sequence: sent, payload: bytes))
        return true
    }

    package mutating func receive(_ record: ReliableUsbRecord, now: TimeInterval) throws -> Data? {
        if !host && record.kind == .hello {
            if let epoch, epoch != record.epoch {
                // Do not acknowledge a new epoch while a previous writer can still own IO.
                throw AoaError.usb("USB host session changed; reopen accessory")
            }
            epoch = record.epoch; ready = true; helloReply = true
            return nil
        }
        guard record.epoch == epoch else { return nil }
        if host && record.kind == .helloAck { ready = true; return nil }
        guard ready, record.kind == .data || record.kind == .ack else { return nil }
        guard record.ack <= emitted else { throw AoaError.protocolViolation("USB ACK exceeds transmitted data") }
        if record.ack > acknowledged {
            acknowledged = record.ack; pending.removeAll { $0.sequence <= acknowledged }; progress = now
            // Reset future intervals only. Advancing scheduled retries would make a delayed
            // cumulative ACK trigger a burst of retransmissions across the remaining window.
            for i in pending.indices { pending[i].retryDelay = 0.5 }
        }
        guard record.kind == .data else { return nil }
        guard received < UInt64(Int64.max), record.sequence == received + 1 else {
            ackAt = now // Duplicate/gap ACK must not wait for a coalescing deadline.
            return nil
        }
        received = record.sequence
        ackRecords += 1
        if ackAt == nil { ackAt = now + 0.002 }
        if ackRecords >= 8 { ackAt = now }
        return record.payload
    }

    /// One writer owns this method and raw IO. ACKs are coalesced and prioritized, so
    /// receive never waits on a blocked bulk write and no unbounded send queue exists.
    package mutating func next(now: TimeInterval) throws -> ReliableUsbRecord? {
        if host && !ready {
            guard now - started < 10 else { throw AoaError.usb("Reliable USB handshake timed out; update both DroidBridge apps") }
            if helloSent == nil || now - helloSent! >= 0.5 {
                helloSent = now
                return try ReliableUsbRecord(kind: .hello, epoch: epoch!)
            }
            return nil
        }
        guard ready, let epoch else { return nil }
        if !pending.isEmpty && now - progress >= Self.noProgressSeconds {
            throw AoaError.usb("Reliable USB delivery made no progress for \(Int(Self.noProgressSeconds)) seconds")
        }
        if helloReply {
            helloReply = false
            return try ReliableUsbRecord(kind: .helloAck, epoch: epoch)
        }
        if let i = pending.firstIndex(where: { $0.retryAt == nil || now >= $0.retryAt! }) {
            if pending[i].retryAt != nil { retransmissions += 1 }
            pending[i].retryAt = now + pending[i].retryDelay
            pending[i].retryDelay = min(pending[i].retryDelay * 2, 2)
            emitted = max(emitted, pending[i].sequence)
            ackAt = nil; ackRecords = 0 // Piggyback ACK cancels its standalone deadline.
            return try ReliableUsbRecord(kind: .data, epoch: epoch, sequence: pending[i].sequence,
                                         ack: received, payload: pending[i].payload)
        }
        if let ackAt, now >= ackAt {
            self.ackAt = nil; ackRecords = 0
            return try ReliableUsbRecord(kind: .ack, epoch: epoch, ack: received)
        }
        return nil
    }

    /// Monotonic deadline for ACK, retry or failure. An idle peer needs no polling.
    package func nextWakeAt(now: TimeInterval) -> TimeInterval? {
        if host && !ready { return min(helloSent.map { $0 + 0.5 } ?? now, started + 10) }
        guard ready else { return nil }
        if helloReply { return now }
        var wake = ackAt
        for packet in pending {
            let retry = packet.retryAt ?? now
            wake = min(wake ?? retry, retry)
        }
        if !pending.isEmpty { wake = min(wake ?? progress + Self.noProgressSeconds, progress + Self.noProgressSeconds) }
        return wake
    }
}
