import Foundation
import Network
import OSLog

public protocol AoaByteTransport: AnyObject, Sendable {
    func readChunk() throws -> Data?
    func write(_ data: Data) throws
    func close()
}

/// The USB envelope only forwards existing authenticated DBP/pairing byte streams.
/// Network callbacks and stream state run on one queue; USB IO never blocks that queue.
public final class AoaMultiplexer: @unchecked Sendable {
    public struct Ports: Sendable { public let relay: UInt16; public let pairing: UInt16 }
    // Every mutation, including NWConnection callbacks, is confined to the mux queue.
    private final class Stream: @unchecked Sendable {
        let connection: NWConnection
        var opened = false
        var reading = false
        var pendingRead: (data: Data?, complete: Bool)?
        var localFIN = false
        var remoteFIN = false
        var pendingWrites = 0
        var sendCredit = AoaFrame.initialCredit
        var receiveCredit = AoaFrame.initialCredit
        var receivedBytes: UInt64 = 0
        var sentBytes: UInt64 = 0
        var consumedBytes: UInt64 = 0
        var windowUpdate = AoaWindowUpdate()
        var refreshedConsumed: UInt64 = 0
        var peerConsumedBytes: UInt64 = 0
        var lastReceived = ContinuousClock.now
        var idleReported = false
        init(_ connection: NWConnection) { self.connection = connection }
    }
    // Mutable only on the mux queue, until the writer takes an immutable copy.
    // Absolute WINDOW updates and unsent PINGs can replace obsolete queued work.
    private final class PendingWrite: @unchecked Sendable {
        var data: Data
        let kind: AoaFrame.Kind
        let id: UInt32
        init(_ data: Data, kind: AoaFrame.Kind, id: UInt32) { self.data = data; self.kind = kind; self.id = id }
    }
    private var transport: (any AoaByteTransport)?
    private let transportFactory: @Sendable () throws -> any AoaByteTransport
    private let disconnected: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "io.droidbridge.aoa.mux")
    private let writer = DispatchQueue(label: "io.droidbridge.aoa.writer")
    private let key = DispatchSpecificKey<Bool>()
    private var streams: [UInt32: Stream] = [:]
    private var listeners: [NWListener] = []
    private var nextID: UInt32 = 1
    private var queuedFrames = 0
    private var pausedReads: Set<UInt32> = []
    private var pendingWindows: [UInt32: PendingWrite] = [:]
    private var pendingPing: PendingWrite?
    // FIFO of frames not yet taken by the writer; it drains several per bulk write.
    private var outbox: [PendingWrite] = []
    private var writerActive = false
    private var windowTimer: DispatchWorkItem?
    private let writerHighWater = 256
    private let writerLowWater = 128
    private var stopped = false
    private var failureReason: String?
    private var sessionReady = false
    private let handshake = DispatchSemaphore(value: 0)
    private let nonce = withUnsafeBytes(of: UUID().uuid) { Data($0) }
    private var lastPong = ContinuousClock.now
    private var enabled: Set<AoaFrame.Service> = [.relay, .pairing]
    private let logger = Logger(subsystem: "io.droidbridge", category: "USBStream")

    public init(transport: any AoaByteTransport, disconnected: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transportFactory = { transport }; self.disconnected = disconnected
        queue.setSpecific(key: key, value: true)
    }

    /// Reserve the loopback ports before a factory may change the phone's USB mode.
    public init(transportFactory: @escaping @Sendable () throws -> any AoaByteTransport,
                disconnected: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transportFactory = transportFactory; self.disconnected = disconnected
        queue.setSpecific(key: key, value: true)
    }

    public func setEnabled(_ services: Set<AoaFrame.Service>) {
        queue.sync { enabled = services }
    }

    public var isConnected: Bool { queue.sync { sessionReady && !stopped } }

    /// Call off the state queue. Zero ports are useful for isolated integration tests.
    public func start(relayPort: UInt16 = 27183, pairingPort: UInt16 = 27184) throws -> Ports {
        do {
            let relay = try listen(port: relayPort, service: .relay)
            let pairing = try listen(port: pairingPort, service: .pairing)
            guard queue.sync(execute: { !stopped }) else { throw AoaError.usb("closed") }
            let transport = try transportFactory()
            let accepted = queue.sync {
                guard !stopped else { return false }
                self.transport = transport
                send(.reset, id: 0, payload: nonce)
                return true
            }
            guard accepted else { transport.close(); throw AoaError.usb("closed") }
            Thread.detachNewThread { [self] in
                do {
                    var decoder = AoaFrameDecoder()
                    while let bytes = try transport.readChunk() {
                        let frames = try decoder.append(bytes)
                        try queue.sync {
                            if stopped { throw AoaError.usb("closed") }
                            for frame in frames { try handle(frame) }
                        }
                    }
                    try decoder.finish()
                    queue.async { self.fail("USB disconnected") }
                } catch { queue.async { self.fail(error.localizedDescription) } }
            }
            guard handshake.wait(timeout: .now() + 60) == .success, isConnected else {
                throw AoaError.usb(queue.sync { failureReason } ?? "open DroidBridge on Android and allow USB access, then retry")
            }
            queue.async { self.heartbeat() }
            return Ports(relay: relay, pairing: pairing)
        } catch { stop(); throw error }
    }

    public func stop() {
        if DispatchQueue.getSpecific(key: key) == true { fail("USB disconnected") }
        else { queue.sync { fail("USB disconnected") } }
    }

    private func listen(port: UInt16, service: AoaFrame.Service) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: ready.signal()
            case .failed:
                ready.signal()
                self?.fail("cannot open local port \(port); another app or ADB may be using it")
            case .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection, service: service) }
        let accepted = queue.sync {
            guard !stopped else { return false }
            listeners.append(listener); listener.start(queue: queue)
            return true
        }
        guard accepted else { listener.cancel(); throw AoaError.usb("closed") }
        let signalled = ready.wait(timeout: .now() + 5) == .success
        let boundPort: NWEndpoint.Port? = queue.sync {
            // NWListener.port can contain the requested port even when bind failed.
            if case .ready = listener.state, !stopped { return listener.port }
            return nil
        }
        guard signalled, let boundPort else {
            throw AoaError.usb("cannot open local port \(port); another app or ADB may be using it")
        }
        return boundPort.rawValue
    }

    private func accept(_ connection: NWConnection, service: AoaFrame.Service) {
        guard !stopped, sessionReady, enabled.contains(service), streams.count < 256,
              !writerBackpressured, nextID <= Int32.max else { connection.cancel(); return }
        let id = nextID; nextID += 2
        let stream = Stream(connection)
        streams[id] = stream
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed = state { closeStream(id, notify: true) }
        }
        connection.start(queue: queue)
        send(.open, id: id, service: service)
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, let current = streams[id], !current.opened else { return }
            closeStream(id, notify: true)
        }
    }

    private func readLocal(_ id: UInt32) {
        guard let stream = streams[id], stream.opened, !stream.reading, !stream.localFIN,
              !stopped else { return }
        guard !writerBackpressured else { pausedReads.insert(id); return }
        pausedReads.remove(id)
        if let pending = stream.pendingRead {
            stream.pendingRead = nil
            forwardLocalRead(id, stream: stream, data: pending.data, complete: pending.complete)
            return
        }
        guard stream.sendCredit > 0 else { return }
        stream.reading = true
        stream.connection.receive(minimumIncompleteLength: 1,
                                  maximumLength: min(AoaFrame.sendPayload, stream.sendCredit)) { [weak self] data, _, complete, error in
            guard let self, let current = streams[id], current === stream, !stopped else { return }
            stream.reading = false
            if error != nil { closeStream(id, notify: true); return }
            // One outstanding receive per stream may finish after pausing. Keep
            // that bounded result (at most 16 KiB) until the writer has space.
            // Idle receives do not reserve global slots and starve other streams.
            if writerBackpressured {
                stream.pendingRead = (data, complete)
                pausedReads.insert(id)
            } else { forwardLocalRead(id, stream: stream, data: data, complete: complete) }
        }
    }

    private func forwardLocalRead(_ id: UInt32, stream: Stream, data: Data?, complete: Bool) {
        if let data, !data.isEmpty {
            stream.sendCredit -= data.count
            stream.sentBytes += UInt64(data.count)
            send(.data, id: id, payload: data)
        }
        if complete {
            stream.localFIN = true
            send(.fin, id: id)
            finishIfDrained(id)
        } else { readLocal(id) }
    }

    private func handle(_ frame: AoaFrame) throws {
        if !sessionReady {
            // Old frames may remain after a normal host restart. RESET_OK is the epoch barrier.
            if frame.type == .resetOK && frame.payload == nonce {
                sessionReady = true; lastPong = .now; handshake.signal()
            }
            return
        }
        if frame.type == .pong { lastPong = .now; return }
        guard frame.streamID > 0 else { throw AoaError.protocolViolation("unexpected session control") }
        guard frame.streamID < nextID else { throw AoaError.protocolViolation("unknown stream") }
        guard let stream = streams[frame.streamID] else { return } // late frame for a retired ID
        let id = frame.streamID
        switch frame.type {
        case .reset, .resetOK, .ping, .pong: throw AoaError.protocolViolation("unexpected session control")
        case .open: throw AoaError.protocolViolation("peer cannot initiate streams")
        case .openOK:
            guard !stream.opened else { throw AoaError.protocolViolation("duplicate OPEN_OK") }
            stream.opened = true; readLocal(id)
        case .close: closeStream(id, notify: false)
        case .window:
            let consumed = AoaFrame.consumedCount(frame.payload)
            guard stream.opened, consumed <= stream.sentBytes else {
                throw AoaError.protocolViolation("credit inflation")
            }
            guard consumed > stream.peerConsumedBytes else { return }
            stream.peerConsumedBytes = consumed
            stream.sendCredit = AoaFrame.initialCredit - Int(stream.sentBytes - consumed)
            readLocal(id)
        case .data:
            guard stream.opened, !stream.remoteFIN, frame.payload.count <= stream.receiveCredit else {
                throw AoaError.protocolViolation("DATA outside receive window")
            }
            stream.receiveCredit -= frame.payload.count
            stream.receivedBytes += UInt64(frame.payload.count)
            stream.lastReceived = .now
            stream.idleReported = false
            stream.pendingWrites += 1
            stream.connection.send(content: frame.payload, completion: .contentProcessed { [weak self] error in
                guard let self, streams[id] === stream else { return }
                stream.pendingWrites -= 1
                if error != nil { closeStream(id, notify: true); return }
                stream.receiveCredit += frame.payload.count
                stream.consumedBytes += UInt64(frame.payload.count)
                if stream.windowUpdate.consumed(stream.consumedBytes, now: ProcessInfo.processInfo.systemUptime) {
                    sendWindow(id, stream)
                } else { armWindowTimer() }
                finishIfDrained(id)
            })
        case .fin:
            guard stream.opened, !stream.remoteFIN else { throw AoaError.protocolViolation("unexpected FIN") }
            stream.remoteFIN = true
            stream.pendingWrites += 1
            stream.connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                   completion: .contentProcessed { [weak self] error in
                guard let self, streams[id] === stream else { return }
                stream.pendingWrites -= 1
                if error != nil { closeStream(id, notify: true) } else { finishIfDrained(id) }
            })
        }
    }

    private func finishIfDrained(_ id: UInt32) {
        guard let stream = streams[id], stream.localFIN, stream.remoteFIN, stream.pendingWrites == 0 else { return }
        closeStream(id, notify: false)
    }
    private func closeStream(_ id: UInt32, notify: Bool) {
        guard let stream = streams.removeValue(forKey: id) else { return }
        pausedReads.remove(id)
        stream.connection.cancel()
        if notify { send(.close, id: id) }
    }

    private var writerBackpressured: Bool { queuedFrames >= writerHighWater }

    private func sendWindow(_ id: UInt32, _ stream: Stream) {
        send(.window,id:id,payload:AoaFrame.consumedBytes(stream.consumedBytes))
        stream.windowUpdate.sent(stream.consumedBytes)
    }

    /// One timer covers all sparse streams. Later packets never postpone an earlier deadline.
    private func armWindowTimer() {
        guard !stopped, windowTimer == nil else { return }
        var first: TimeInterval?
        for stream in streams.values {
            if let due = stream.windowUpdate.deadline { first = min(first ?? due,due) }
        }
        guard let first else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !stopped else { return }
            windowTimer = nil
            let now = ProcessInfo.processInfo.systemUptime
            for (id,stream) in streams where stream.windowUpdate.isDue(now) { sendWindow(id,stream) }
            armWindowTimer()
        }
        windowTimer = work
        queue.asyncAfter(deadline:.now()+max(0,first-ProcessInfo.processInfo.systemUptime),execute:work)
    }

    private func resumeLocalReads() {
        guard !stopped, !pausedReads.isEmpty,
              queuedFrames <= writerLowWater else { return }
        let ready = pausedReads
        pausedReads.removeAll(keepingCapacity: true)
        for id in ready { readLocal(id) }
    }

    private func send(_ kind: AoaFrame.Kind, id: UInt32, service: AoaFrame.Service = .none, payload: Data = Data()) {
        guard !stopped, let transport else { return }
        do {
            let data = try AoaFrame(type: kind, streamID: id, service: service, payload: payload).encoded()
            if kind == .window, let pending = pendingWindows[id] {
                pending.data = data
                return
            }
            if kind == .ping, pendingPing != nil { return }
            // The remaining space is reserved for credit, close and heartbeat
            // traffic while producers are paused; never discard ordered DATA.
            guard queuedFrames < 1024 else { fail("USB writer queue exceeded"); return }
            let pending = PendingWrite(data, kind: kind, id: id)
            if kind == .window { pendingWindows[id] = pending }
            if kind == .ping { pendingPing = pending }
            queuedFrames += 1
            outbox.append(pending)
            if !writerActive {
                writerActive = true
                writer.async { [self] in drainOutbox(transport) }
            }
        } catch { fail(error.localizedDescription) }
    }

    /// Writer queue only. Packs queued frames into one bulk write: WINDOW/FIN/PING/small DATA
    /// otherwise each cost a reliable record, two digests and a USB transfer.
    private func drainOutbox(_ transport: any AoaByteTransport) {
        while true {
            // A preceding write can fail while more frames are already queued.
            // Synchronize with its failure/Stop before touching the transport again.
            let batch: (bytes: Data, count: Int)? = queue.sync {
                guard !stopped, !outbox.isEmpty else { writerActive = false; return nil }
                var bytes = Data()
                var count = 0
                for pending in outbox {
                    if count > 0 && bytes.count + pending.data.count > AoaFrame.writeBudget { break }
                    if pending.kind == .window, pendingWindows[pending.id] === pending { pendingWindows.removeValue(forKey: pending.id) }
                    if pending.kind == .ping, pendingPing === pending { pendingPing = nil }
                    bytes.append(pending.data)
                    count += 1
                }
                outbox.removeFirst(count)
                return (bytes, count)
            }
            guard let batch else { return }
            do { try transport.write(batch.bytes); queue.async { self.writeFinished(batch.count) } }
            catch { queue.async { self.fail(error.localizedDescription); self.writeFinished(batch.count) }; return }
        }
    }

    private func writeFinished(_ count: Int) {
        queuedFrames -= count
        resumeLocalReads()
    }
    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        windowTimer?.cancel(); windowTimer = nil
        failureReason = message
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        streams.values.forEach { $0.connection.cancel() }; streams.removeAll()
        pausedReads.removeAll()
        pendingWindows.removeAll()
        pendingPing = nil
        outbox.removeAll()
        // close must wake a blocked USB reader/writer; no callback is allowed to re-open a stream.
        transport?.close()
        handshake.signal()
        disconnected(message)
    }

    private func heartbeat() {
        guard !stopped else { return }
        // Outlast the reliable channel's no-progress deadline, so it decides first and a
        // frozen-then-resumed phone keeps its streams.
        guard lastPong.duration(to: .now) < .seconds(ReliableUsbState.noProgressSeconds + 10) else { fail("Android USB relay stopped responding"); return }
        // Repeat absolute consumption, including when DATA is stalled. A missing WINDOW no
        // longer leaks the stream's credit permanently; duplicate refreshes are idempotent.
        // Only consumption not repeated yet: idle streams cost nothing, while a lost update
        // is still repeated once without new data.
        for (id, stream) in streams where stream.opened && stream.consumedBytes > stream.refreshedConsumed {
            sendWindow(id, stream)
            stream.refreshedConsumed = stream.consumedBytes
        }
        // One metadata-only record per idle interval of a large stream. This distinguishes
        // downstream pressure from missing upstream data without changing flow control.
        for (id, stream) in streams where stream.receivedBytes >= 1_048_576 && !stream.remoteFIN && !stream.idleReported {
            if stream.lastReceived.duration(to: .now) >= .seconds(10) {
                stream.idleReported = true
                logger.info("Large stream idle: id=\(id) rx=\(stream.receivedBytes) tx=\(stream.sentBytes) rxCredit=\(stream.receiveCredit) txCredit=\(stream.sendCredit) pendingWrites=\(stream.pendingWrites) queuedFrames=\(self.queuedFrames)")
            }
        }
        send(.ping, id: 0)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.heartbeat() }
    }
}
