import Foundation
import DroidBridgeShared

private final class RecoveryPacketSource: PacketSource {
    func read(_ handler: @escaping @Sendable ([Data]) -> Void) {}
    func write(_ packets: [Data]) {}
}

private final class RecoveryIngester: PacketIngesting {
    func ingest(_ packet: Data) {}
}

func runAlreadyRecoveredReconnectCheck() throws {
    let configuration = try TunnelRuntimeConfiguration(
        deviceSerial: "aoa:test", relayHost: "127.0.0.1", relayPort: 27183,
        pairedPeerId: "test", keychainAccount: "test", maximumFlows: 4
    )
    // Neither an actual utun nor a connection to the live phone is used here.
    let service = HelperService(healthProbe: { _, _ in throw CancellationError() })
    let controller = TunnelController(packetSource: RecoveryPacketSource(), secret: Data(count: 32),
                                      engineFactory: { _, _ in RecoveryIngester() })
    precondition(controller.start())
    defer { controller.stop() }
    service.seedRelayForChecks(controller, configuration: configuration, status: .blockedRelay)
    var oldSnapshot: TunnelMetricsSnapshot?
    service.status { oldSnapshot = try? JSONDecoder().decode(TunnelMetricsSnapshot.self, from: $0) }
    precondition(oldSnapshot?.runtimeStatus == .blockedRelay)

    // Health recovery wins after the GUI reads status, before its reconnect reaches XPC.
    service.seedRelayForChecks(controller, configuration: configuration, status: .running)
    let generation = service.healthGenerationForChecks
    for _ in 0..<2 {
        var accepted = false
        service.reconnectTunnel { accepted = $0 && $1 == nil }
        precondition(accepted, "An already recovered tunnel accepts a redundant request")
        var current: TunnelMetricsSnapshot?
        service.status { current = try? JSONDecoder().decode(TunnelMetricsSnapshot.self, from: $0) }
        guard current?.runtimeStatus == .running,
              service.healthGenerationForChecks == generation else {
            FileHandle.standardError.write(Data("FAIL: stale reconnect must preserve the running engine and health monitor\n".utf8))
            exit(EXIT_FAILURE)
        }
    }
    precondition(!controller.start(), "The original running session must remain active")
    print("already recovered helper reconnect: passed")
}
