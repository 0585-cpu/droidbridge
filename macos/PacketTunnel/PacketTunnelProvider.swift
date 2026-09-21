import NetworkExtension
import DroidBridgeShared

/// B1 Packet Tunnel: validate config + secret + relay health, apply full-tunnel settings, then run the
/// C/lwIP data plane through the Android relay. Fail-closed: relay/cellular loss keeps settings and drops
/// packets; only explicit Disconnect removes settings.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private var controller: TunnelController?
    private var healthMonitor: RelayHealthMonitor?

    override func startTunnel(options: [String: NSObject]? = nil, completionHandler: @escaping (Error?) -> Void) {
        let providerConfig = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let configData = providerConfig?["runtimeConfig"] as? Data
        guard let configData, let config = try? JSONDecoder().decode(TunnelRuntimeConfiguration.self, from: configData) else {
            completionHandler(DroidBridgeError.invalidConfiguration("missing runtime config"))
            return
        }
        let store = KeychainPairingSecretStore(accessGroup: "io.droidbridge.shared")
        guard let secret = try? store.load(peerId: config.keychainAccount), secret.count == 32 else {
            completionHandler(DroidBridgeError.secretWrongLength)
            return
        }

        let settings = TunnelSettings.make()
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error { completionHandler(error); return }
            let controller = TunnelController(packetFlow: self.packetFlow, secret: secret,
                                              relayHost: config.relayHost, relayPort: config.relayPort)
            controller.start()
            self.controller = controller
            let monitor = RelayHealthMonitor(secret: secret,
                onReady: { _ in }, onUnavailable: { /* fail closed: keep settings, engine drops packets */ })
            monitor.start()
            self.healthMonitor = monitor
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        healthMonitor?.stop()
        controller?.stop()
        healthMonitor = nil
        controller = nil
        completionHandler()
    }
}
