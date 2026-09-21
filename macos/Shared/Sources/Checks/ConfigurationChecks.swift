import DroidBridgeShared
import Foundation

func runConfigurationChecks(_ r: CheckRunner) {
    func valid(_ flows: UInt16 = 128, host: String = "127.0.0.1", port: UInt16 = 27183) throws -> TunnelRuntimeConfiguration {
        try TunnelRuntimeConfiguration(deviceSerial: "R58M123456A", relayHost: host, relayPort: port,
                                       pairedPeerId: "peer-1", keychainAccount: "peer-1", maximumFlows: flows)
    }

    // JSON round trip, and no "secret" substring in serialized config
    if let config = try? valid(), let data = try? JSONEncoder.droidBridge.encode(config) {
        let decoded = try? JSONDecoder().decode(TunnelRuntimeConfiguration.self, from: data)
        r.check(decoded == config, "config round trips")
        r.check(!String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("secret"), "no secret in json")
    } else {
        r.check(false, "valid config encodes")
    }

    r.expectThrows("non-loopback host") { try valid(host: "10.0.0.1") }
    r.expectThrows("wrong port") { try valid(port: 27184) }
    r.expectThrows("flows 0") { try valid(0) }
    r.expectThrows("flows 257") { try valid(257) }
    r.check((try? valid(256)) != nil, "flows 256 allowed")
    r.finish("configuration")
}
