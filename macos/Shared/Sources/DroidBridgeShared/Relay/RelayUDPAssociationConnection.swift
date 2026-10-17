import Foundation

public protocol RelayUDPAssociationDelegate: AnyObject, Sendable {
    func relayUDPAssociationReceived(_ token: UUID, peer: UDPAssociationPeer, data: Data) async
    func relayUDPAssociationClosed(_ token: UUID)
}

/// One authenticated stream and cellular UDP socket per Mac source endpoint.
public actor RelayUDPAssociationConnection {
    public let token: UUID
    private let family: UInt8
    private let session: RelaySession
    private weak var delegate: (any RelayUDPAssociationDelegate)?
    private let queue = UDPAssociationQueue()
    private var opened = false
    private var closed = false
    private var sending = false
    private var sequence: UInt32 = 0
    public init(token: UUID, family: UInt8, secret: Data, transport: any RelayTransport,
                delegate: any RelayUDPAssociationDelegate, clientNonce: UInt64 = .random(in: 1 ... .max)) {
        self.token = token; self.family = family; self.delegate = delegate
        session = RelaySession(transport: transport, secret: secret, clientNonce: clientNonce, now: { UInt64(Date().timeIntervalSince1970) })
    }
    public nonisolated var drops: UInt64 { queue.drops }
    public nonisolated func register(flow: UInt32, peer: UDPAssociationPeer) { queue.register(flow: flow, peer: peer) }
    public nonisolated func remove(flow: UInt32) { queue.remove(flow: flow) }
    public nonisolated func enqueueFromCore(flow: UInt32, data: Data) {
        if queue.append(flow: flow, payload: data) { Task { await self.pump() } }
    }
    public func start(timeout: Duration = .seconds(10)) async throws {
        guard !closed else { throw CancellationError() }
        let transport = session.transport
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await self.open() }
                    group.addTask { try await Task.sleep(for: timeout); await transport.cancel(); throw DroidBridgeError.relayTimedOut }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
            } onCancel: { Task { await transport.cancel() } }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            opened = true
            Task { await self.receiveLoop() }
            Task { await self.pump() }
        } catch { await close(); throw error }
    }
    private func open() async throws {
        let nonce = try await session.hello()
        guard !closed else { throw CancellationError() }
        try await session.send(.openUDPAssociation, serverNonce: nonce, payload: DbpCodec.encodeOpenUDPAssociation(family: family))
        let (header, payload) = try await session.read(serverNonce: nonce)
        let bytes = [UInt8](payload)
        guard !closed, header.type == .openUDPOk, bytes.count == 8,
              (30...300).contains(wireRead(bytes,4,2)), wireRead(bytes,6,2) == UInt64(DatagramFrame.maximumPayload) else {
            throw DroidBridgeError.relayProtocol("UDP association refused")
        }
    }
    public func close() async {
        guard !closed else { return }
        closed = true; opened = false; queue.close()
        await session.transport.cancel()
        delegate?.relayUDPAssociationClosed(token)
    }
    private func pump() async {
        guard opened, !closed, !sending else { return }
        sending = true
        defer { sending = false }
        do {
            while !closed, let packet = queue.pop() {
                guard packet.peer.family == family else { throw DroidBridgeError.relayProtocol("association family") }
                let frame = try UDPAssociationFrame(peer: packet.peer, payload: packet.payload, inbound: false, sequence: sequence).encoded()
                sequence &+= 1
                try await session.transport.send(frame)
            }
        } catch { await close() }
    }
    private func receiveLoop() async {
        do {
            while !closed {
                let header = try await session.transport.receiveExactly(UDPAssociationFrame.headerSize)
                let length = try UDPAssociationFrame.payloadLength(header: header)
                // Reject direction/family before receiving the body.
                let bytes = [UInt8](header)
                guard bytes[2] == 1, bytes[3] == family else { throw DroidBridgeError.relayProtocol("association direction/family") }
                let payload = length == 0 ? Data() : try await session.transport.receiveExactly(length)
                let frame = try UDPAssociationFrame.decode(header + payload)
                guard !closed else { return }
                await delegate?.relayUDPAssociationReceived(token, peer: frame.peer, data: frame.payload)
            }
        } catch { await close() }
    }
}
