import Foundation
import Network

/// Loopback NWConnection to the Android pairing endpoint (127.0.0.1:27184), 4-byte length-framed.
public actor NetworkPairingConnection: PairingConnection {
    private let connection: NWConnection

    public init(host: String = "127.0.0.1", port: UInt16 = 27184) {
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: .tcp)
    }

    public func start() async throws {
        connection.start(queue: .global())
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: cont.resume()
                case .failed(let error): cont.resume(throwing: error)
                case .cancelled: cont.resume(throwing: DroidBridgeError.pairingProtocol("connection cancelled"))
                default: break
                }
            }
        }
        connection.stateUpdateHandler = nil
    }

    public func sendFrame(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func receiveFrame() async throws -> Data {
        let header = try await receiveExactly(4)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= PairingFraming.maxFrame else { throw DroidBridgeError.pairingProtocol("frame length") }
        return header + (try await receiveExactly(length))
    }

    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let error { cont.resume(throwing: error) }
                else if let data, data.count == count { cont.resume(returning: data) }
                else { cont.resume(throwing: DroidBridgeError.pairingProtocol("peer closed")) }
            }
        }
    }

    public func close() async { connection.cancel() }
}
