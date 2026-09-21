import NetworkExtension
import DroidBridgeShared

/// B1 control-plane milestone ships an intentionally unavailable data plane; the real tunnel lands in
/// the Packet Tunnel plan. Starting it must fail closed with a typed error, never silently no-op.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String: NSObject]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(DroidBridgeError.dataPlaneNotInstalled)
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}
