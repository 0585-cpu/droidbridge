import Foundation
import Network

private final class NetworkContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func once(_ body: () -> Void) {
        let shouldRun = lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldRun { body() }
    }
}

/// Byte transport for a relay flow: a loopback TCP connection to the Android relay. Abstracted so the
/// flow logic is testable without a real socket.
public protocol RelayTransport: Sendable {
    func start() async throws
    func send(_ data: Data) async throws
    /// Sends TCP FIN after prior sends; the receive direction remains usable.
    func finishSending() async throws
    /// Reads exactly `count` bytes (for framed control messages). Throws on EOF before `count`.
    func receiveExactly(_ count: Int) async throws -> Data
    /// Reads up to `maxLength` bytes of the raw stream; returns empty Data on clean EOF.
    func receive(maxLength: Int) async throws -> Data
    func cancel() async
}

/// NWConnection-backed transport to 127.0.0.1:relayPort.
public actor NWConnectionTransport: RelayTransport {
    private let connection: NWConnection
    private var receivedEOF = false

    public init(host: String = "127.0.0.1", port: UInt16 = 27183) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    public func start() async throws {
        let connection = self.connection
        connection.start(queue: .global())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let gate = NetworkContinuationGate()
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.once { cont.resume() }
                    case .failed(let error): gate.once { cont.resume(throwing: error) }
                    case .cancelled:
                        gate.once {
                            cont.resume(throwing: DroidBridgeError.relayProtocol("cancelled"))
                        }
                    default: break
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        connection.stateUpdateHandler = nil
    }

    public func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func receiveExactly(_ count: Int) async throws -> Data {
        if count == 0 { return Data() }
        guard !receivedEOF else { throw DroidBridgeError.relayProtocol("peer closed") }
        let connection = self.connection
        let (bytes, complete) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Bool), Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, complete, error in
                    if let error { cont.resume(throwing: error) }
                    else if let data, data.count == count { cont.resume(returning: (data, complete)) }
                    else { cont.resume(throwing: DroidBridgeError.relayProtocol(data?.isEmpty == false ? "truncated frame" : "peer closed")) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
        receivedEOF = complete
        return bytes
    }

    public func finishSending() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func receive(maxLength: Int) async throws -> Data {
        guard !receivedEOF else { return Data() }
        let (bytes, complete) = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, Bool), Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else { cont.resume(returning: (data ?? Data(), isComplete)) }
            }
        }
        // NWConnection may deliver final bytes and EOF together. Another receive after
        // that callback reports ENOSTR (96), which would falsely reset a clean download
        // and discard the packet engine's still-buffered tail.
        receivedEOF = complete
        return bytes
    }

    public func cancel() async { connection.cancel() }
}
