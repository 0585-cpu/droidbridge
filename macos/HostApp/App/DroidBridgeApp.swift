import SwiftUI
import DroidBridgeShared

/// Menu-bar host app. The coordinator/adapter are constructed lazily; the real ADB + relay wiring is
/// assembled here. The Packet Tunnel is intentionally not started in the control-plane milestone.
@main
struct DroidBridgeApp: App {
    @State private var adapter = DroidBridgeApp.makeAdapter()

    var body: some Scene {
        MenuBarExtra("DroidBridge", systemImage: "cable.connector") {
            MenuBarContentView(adapter: adapter)
        }
        .menuBarExtraStyle(.window)
    }

    @MainActor
    private static func makeAdapter() -> DroidBridgeCoordinatorAdapter {
        let executable = (try? AdbExecutableLocator().locate()) ?? URL(fileURLWithPath: "/opt/homebrew/bin/adb")
        let adb = AdbClient(executable: executable, runner: FoundationProcessRunner())
        let core = DroidBridgeCoordinatorCore(adb: adb, secretStore: KeychainPairingSecretStore(accessGroup: "io.droidbridge.shared"))
        return DroidBridgeCoordinatorAdapter(core: core, devices: { (try? await adb.devices()) ?? [] })
    }
}
