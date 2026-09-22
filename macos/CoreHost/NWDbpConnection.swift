import Foundation
import DroidBridgeShared

/// Adapts a started RelayTransport to the frame-oriented DbpConnection the RelayControlClient expects.
struct NWDbpConnection: DbpConnection {
    let transport: any RelayTransport
    func send(_ data: Data) async throws { try await transport.send(data) }
    func receiveExactly(_ count: Int) async throws -> Data { try await transport.receiveExactly(count) }
    func close() async { await transport.cancel() }
}
