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
        let secretStore = KeychainPairingSecretStore(accessGroup: "io.droidbridge.shared")
        let core = DroidBridgeCoordinatorCore(adb: adb, secretStore: secretStore)
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DroidBridge", isDirectory: true)
        let configurationDirectory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.io.droidbridge.shared"
        ) ?? fallback
        return DroidBridgeCoordinatorAdapter(
            core: core,
            devices: { (try? await adb.devices()) ?? [] },
            helper: HelperClient(),
            configStore: FileRuntimeConfigurationStore(directory: configurationDirectory),
            secretStore: secretStore
        )
    }
}
