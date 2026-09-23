import Foundation
import Network

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
        var localFIN = false
        var remoteFIN = false
        var pendingWrites = 0
        var sendCredit = AoaFrame.initialCredit
        var receiveCredit = AoaFrame.initialCredit
        init(_ connection: NWConnection) { self.connection = connection }
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
    private var stopped = false
    private var sessionReady = false
    private let handshake = DispatchSemaphore(value: 0)
    private let nonce = withUnsafeBytes(of: UUID().uuid) { Data($0) }
    private var lastPong = ContinuousClock.now
    private var enabled: Set<AoaFrame.Service> = [.relay, .pairing]

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
            let transport = try transportFactory()
            queue.sync { self.transport = transport; send(.reset, id: 0, payload: nonce) }
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
                throw AoaError.usb("open DroidBridge on Android and allow USB access, then retry")
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
        queue.sync { listeners.append(listener); listener.start(queue: queue) }
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
              nextID <= Int32.max else { connection.cancel(); return }
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
              stream.sendCredit > 0, !stopped else { return }
        stream.reading = true
        stream.connection.receive(minimumIncompleteLength: 1,
                                  maximumLength: min(AoaFrame.maximumPayload, stream.sendCredit)) { [weak self] data, _, complete, error in
            guard let self, let current = streams[id], current === stream else { return }
            stream.reading = false
            if error != nil { closeStream(id, notify: true); return }
            if let data, !data.isEmpty {
                stream.sendCredit -= data.count
                send(.data, id: id, payload: data)
            }
            if complete {
                stream.localFIN = true
                send(.fin, id: id)
                finishIfDrained(id)
            } else { readLocal(id) }
        }
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
            let amount = Int(AoaFrame.number(frame.payload))
            guard stream.opened, stream.sendCredit <= AoaFrame.initialCredit - amount else {
                throw AoaError.protocolViolation("credit inflation")
            }
            stream.sendCredit += amount; readLocal(id)
        case .data:
            guard stream.opened, !stream.remoteFIN, frame.payload.count <= stream.receiveCredit else {
                throw AoaError.protocolViolation("DATA outside receive window")
            }
            stream.receiveCredit -= frame.payload.count
            stream.pendingWrites += 1
            stream.connection.send(content: frame.payload, completion: .contentProcessed { [weak self] error in
                guard let self, streams[id] === stream else { return }
                stream.pendingWrites -= 1
                if error != nil { closeStream(id, notify: true); return }
                stream.receiveCredit += frame.payload.count
                send(.window, id: id, payload: AoaFrame.bytes(UInt32(frame.payload.count)))
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
        stream.connection.cancel()
        if notify { send(.close, id: id) }
    }
    private func send(_ kind: AoaFrame.Kind, id: UInt32, service: AoaFrame.Service = .none, payload: Data = Data()) {
        guard !stopped, let transport else { return }
        guard queuedFrames < 1024 else { fail("USB writer queue exceeded"); return }
        do {
            let data = try AoaFrame(type: kind, streamID: id, service: service, payload: payload).encoded()
            queuedFrames += 1
            writer.async { [self] in
                do { try transport.write(data); queue.async { self.queuedFrames -= 1 } }
                catch { queue.async { self.queuedFrames -= 1; self.fail(error.localizedDescription) } }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func fail(_ message: String) {
        guard !stopped else { return }
        stopped = true
        listeners.forEach { $0.cancel() }; listeners.removeAll()
        streams.values.forEach { $0.connection.cancel() }; streams.removeAll()
        // close must wake a blocked USB reader/writer; no callback is allowed to re-open a stream.
        transport?.close()
        handshake.signal()
        disconnected(message)
    }

    private func heartbeat() {
        guard !stopped else { return }
        guard lastPong.duration(to: .now) < .seconds(8) else { fail("Android USB relay stopped responding"); return }
        send(.ping, id: 0)
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.heartbeat() }
    }
}
