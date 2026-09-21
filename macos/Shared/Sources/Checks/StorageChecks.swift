import DroidBridgeShared
import Foundation

func runStorageChecks(_ r: CheckRunner) {
    // secret store
    let store = InMemoryPairingSecretStore()
    r.expectThrows("31-byte secret") { try store.save(Data(repeating: 1, count: 31), peerId: "peer") }
    try? store.save(Data(repeating: 2, count: 32), peerId: "peer")
    r.check((try? store.load(peerId: "peer")) == Data(repeating: 2, count: 32), "secret round trips")
    try? store.delete(peerId: "peer")
    r.check((try? store.load(peerId: "peer")) == nil && store.deleteCount == 1, "delete removes secret")

    // runtime config file store
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dbcfg-\(UUID().uuidString)")
    let cfgStore = FileRuntimeConfigurationStore(directory: dir)
    guard let config = try? TunnelRuntimeConfiguration(
        deviceSerial: "R1", relayHost: "127.0.0.1", relayPort: 27183,
        pairedPeerId: "p", keychainAccount: "p", maximumFlows: 128) else { r.check(false, "config builds"); return }
    do {
        try cfgStore.write(config)
        let perms = (try FileManager.default.attributesOfItem(atPath: cfgStore.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue
        r.check(perms == 0o600, "runtime file is 0600")
        let leftover = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.contains { $0.hasSuffix(".tmp") } ?? true
        r.check(!leftover, "no temp file left behind")
        r.check((try? cfgStore.read()) == config, "runtime config round trips")
        // replace existing
        let config2 = try TunnelRuntimeConfiguration(deviceSerial: "R2", relayHost: "127.0.0.1", relayPort: 27183, pairedPeerId: "p2", keychainAccount: "p2", maximumFlows: 64)
        try cfgStore.write(config2)
        r.check((try? cfgStore.read())?.deviceSerial == "R2", "replaces existing config")
        // corrupted json
        try Data("not json".utf8).write(to: cfgStore.fileURL)
        do { _ = try cfgStore.read(); r.check(false, "corrupted json throws") } catch { r.check(true, "corrupted json throws") }
    } catch {
        r.check(false, "runtime store write failed: \(error)")
    }
    try? FileManager.default.removeItem(at: dir)
    r.finish("storage")
}
