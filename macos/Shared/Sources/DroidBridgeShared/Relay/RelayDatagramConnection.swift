import Foundation

public protocol RelayDatagramDelegate: AnyObject, Sendable {
    func relayDatagramReceived(_ flow: UInt32, data: Data) async
    func relayDatagramClosed(_ flow: UInt32)
}

/// One connected cellular UDP tuple per authenticated byte stream; no datagram boundary is lost.
public actor RelayDatagramConnection {
    public let flowId: UInt32
    private let destination: OpenDestination
    private let session: RelaySession
    private weak var delegate: (any RelayDatagramDelegate)?
    private let queue = DatagramQueue()
    private var opened = false
    private var closed = false
    private var sending = false
    private var sequence: UInt32 = 0
    private var expectedSequence: UInt32 = 0
    private var gaps: UInt64 = 0
    private var receivedSequence = false
    public init(flowId: UInt32, destination: OpenDestination, secret: Data, transport: any RelayTransport,
                delegate: any RelayDatagramDelegate, clientNonce: UInt64 = .random(in: 1 ... .max)) {
        self.flowId = flowId; self.destination = destination; self.delegate = delegate
        session = RelaySession(transport: transport, secret: secret, clientNonce: clientNonce, now: { UInt64(Date().timeIntervalSince1970) })
    }
    public nonisolated var drops: UInt64 { queue.drops }
    public var sequenceGaps: UInt64 { gaps }
    public nonisolated func enqueueFromCore(_ data: Data) {
        if queue.append(data) { Task { await self.pump() } }
    }
    public func start(timeout: Duration = .seconds(10)) async throws {
        guard !closed else { throw CancellationError() }
        // Deadline closes the socket only on failure; successful streams remain owned by this actor.
        let transport = session.transport
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.open() }
                group.addTask { try await Task.sleep(for: timeout); await transport.cancel(); throw DroidBridgeError.relayTimedOut }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            guard !closed else { throw CancellationError() }
            opened = true
            Task { await self.receiveLoop() }
            Task { await self.pump() }
        } catch { await close(); throw error }
    }
    private func open() async throws {
        let nonce = try await session.hello()
        guard !closed else { throw CancellationError() }
        try await session.send(.openUDP, serverNonce: nonce, payload: DbpCodec.encodeOpenUDP(destination: destination))
        let (header, payload) = try await session.read(serverNonce: nonce)
        let b = [UInt8](payload)
        guard !closed, header.type == .openUDPOk, b.count == 8,
              (30...300).contains(wireRead(b,4,2)), wireRead(b,6,2) == 1232 else { throw DroidBridgeError.relayProtocol("UDP open refused") }
    }
    public func close() async {
        guard !closed else { return }
        closed = true; opened = false; queue.close()
        await session.transport.cancel()
        delegate?.relayDatagramClosed(flowId)
    }
    private func pump() async {
        guard opened, !closed, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            while !closed, let payload = queue.pop() {
                let frame = try DatagramFrame(payload: payload, inbound: false, sequence: sequence).encoded()
                sequence &+= 1
                try await session.transport.send(frame)
            }
        } catch { await close() }
    }
    private func receiveLoop() async {
        do {
            while !closed {
                let header = try await session.transport.receiveExactly(8)
                let length = try DatagramFrame.payloadLength(header: header)
                let data = length == 0 ? Data() : try await session.transport.receiveExactly(length)
                let frame = try DatagramFrame.decode(header + data)
                guard frame.inbound else { throw DroidBridgeError.relayProtocol("UDP direction") }
                guard !closed else { return }
                if receivedSequence && frame.sequence != expectedSequence { gaps &+= 1 }
                receivedSequence = true; expectedSequence = frame.sequence &+ 1
                await delegate?.relayDatagramReceived(flowId, data: frame.payload)
            }
        } catch { await close() }
    }
}
