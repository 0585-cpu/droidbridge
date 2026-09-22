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
    /// Reads exactly `count` bytes (for framed control messages). Throws on EOF before `count`.
    func receiveExactly(_ count: Int) async throws -> Data
    /// Reads up to `maxLength` bytes of the raw stream; returns empty Data on clean EOF.
    func receive(maxLength: Int) async throws -> Data
    func cancel() async
}

/// NWConnection-backed transport to 127.0.0.1:relayPort.
public actor NWConnectionTransport: RelayTransport {
    private let connection: NWConnection

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
        let connection = self.connection
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                    if let error { cont.resume(throwing: error) }
                    else if let data, data.count == count { cont.resume(returning: data) }
                    else { cont.resume(throwing: DroidBridgeError.relayProtocol("peer closed")) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func receive(maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) }
                else if let data, !data.isEmpty { cont.resume(returning: data) }
                else if isComplete { cont.resume(returning: Data()) } // clean EOF
                else { cont.resume(returning: Data()) }
            }
        }
    }

    public func cancel() async { connection.cancel() }
}
