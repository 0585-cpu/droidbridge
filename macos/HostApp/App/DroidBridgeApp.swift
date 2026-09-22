import SwiftUI
import DroidBridgeShared

/// Menu-bar host app. The coordinator/adapter are constructed lazily; the real ADB, pairing, relay,
/// and privileged-helper wiring is assembled here.
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
        guard let keychainAccessGroup = RuntimeSigningIdentity.keychainAccessGroup() else {
            preconditionFailure("DroidBridgeTeamIdentifier is missing or invalid")
        }
        let secretStore = KeychainPairingSecretStore(accessGroup: keychainAccessGroup)
        let core = DroidBridgeCoordinatorCore(adb: adb, secretStore: secretStore)
        let fallback = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DroidBridge", isDirectory: true)
        let configurationDirectory = RuntimeConfigurationDirectoryResolver.resolve(
            appGroupContainer: FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: "group.io.droidbridge.shared"
            ),
            fallbackDirectory: fallback
        )
        return DroidBridgeCoordinatorAdapter(
            core: core,
            devices: { (try? await adb.devices()) ?? [] },
            adb: adb,
            helper: HelperClient(),
            configStore: FileRuntimeConfigurationStore(directory: configurationDirectory),
            secretStore: secretStore
        )
    }
}
