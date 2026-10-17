import SwiftUI
import DroidBridgeShared

/// One readable connection window plus a compact menu-bar entry point.
@main
struct DroidBridgeApp: App {
    @State private var adapter = DroidBridgeApp.makeAdapter()

    var body: some Scene {
        Window("DroidBridge", id: "connection") {
            MenuBarContentView(adapter: adapter)
        }
        .defaultSize(width: 460, height: 720)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                // Never disabled: quitting is how a user escapes a stuck operation.
                Button("DroidBridge 종료") { Task { await quitDroidBridge(adapter) } }
                    .keyboardShortcut("q")
            }
        }

        MenuBarExtra("DroidBridge", systemImage: "cable.connector") {
            DroidBridgeQuickMenu(adapter: adapter)
        }
    }

    @MainActor
    private static func makeAdapter() -> DroidBridgeCoordinatorAdapter {
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libusb-1.0.0.dylib")
        let adb = AoaDeviceLink(libraryPath: library.path)
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
        let adapter = DroidBridgeCoordinatorAdapter(
            core: core,
            devices: { try await adb.devices() },
            adb: adb,
            helper: HelperClient(),
            configStore: FileRuntimeConfigurationStore(directory: configurationDirectory),
            secretStore: secretStore
        )
        Task {
            await adb.setRecoveryHandler { [weak adapter] in await adapter?.usbSessionRecovered() }
        }
        return adapter
    }
}

private struct DroidBridgeQuickMenu: View {
    @Bindable var adapter: DroidBridgeCoordinatorAdapter
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(HostConnectionPresentation.make(
            state: adapter.state, runtime: adapter.tunnelMetrics?.runtimeStatus,
            tunnelActive: adapter.tunnelRunning, busy: adapter.helperOperationInProgress,
            paired: adapter.canPrepareRelay
        ).title)
        Button("DroidBridge 열기") {
            openWindow(id: "connection")
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if adapter.tunnelRunning {
            Button("연결 해제") { Task { await adapter.disconnect() } }
                .disabled(adapter.helperOperationInProgress)
        }
        Divider()
        Button("종료") { Task { await quitDroidBridge(adapter) } }
    }
}

@MainActor
private func quitDroidBridge(_ adapter: DroidBridgeCoordinatorAdapter) async {
    await adapter.disconnect()
    // disconnect() skips while another operation runs; restore through the helper regardless.
    if adapter.tunnelRunning || adapter.operationInProgress, !(await adapter.stopForQuit()) {
        // Stay open so fail-closed protection can still be released, but never silently.
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "DroidBridge를 종료하지 못했어요"
        alert.informativeText = adapter.networkRecoveryMessage ?? "네트워크 설정을 복원하지 못했어요."
        alert.runModal()
        return
    }
    NSApplication.shared.terminate(nil)
}
