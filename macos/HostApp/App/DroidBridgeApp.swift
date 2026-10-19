import SwiftUI
import DroidBridgeShared

/// One readable connection window plus a compact menu-bar entry point.
@main
struct DroidBridgeApp: App {
    // The delegate owns the adapter so every termination path can restore the network first.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var adapter: DroidBridgeCoordinatorAdapter { appDelegate.adapter }

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
                Button("DroidBridge 종료") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }

        MenuBarExtra("DroidBridge", systemImage: "cable.connector") {
            DroidBridgeQuickMenu(adapter: adapter)
        }
    }

    @MainActor
    fileprivate static func makeAdapter() -> DroidBridgeCoordinatorAdapter {
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
        Button("종료") { NSApplication.shared.terminate(nil) }
    }
}

/// Every quit — menu, ⌘Q, Dock, AppleScript, logout or shutdown — arrives here. The helper keeps
/// the tunnel and kill-switch after the app exits, so quitting without a Stop left the Mac
/// fail-closed and offline with nothing left to release it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let adapter = DroidBridgeApp.makeAdapter()
    private var restored = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if restored || (!adapter.tunnelRunning && !adapter.operationInProgress) { return .terminateNow }
        Task { @MainActor in
            // Straight to the helper: a graceful USB disconnect can wait on a wedged phone, and
            // a second Quit then forces exit before the network is restored.
            let ok = await adapter.stopForQuit()
            if !ok {
                // Stay open so fail-closed protection can still be released, but never silently.
                NSApplication.shared.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "DroidBridge를 종료하지 못했어요"
                alert.informativeText = adapter.networkRecoveryMessage ?? "네트워크 설정을 복원하지 못했어요."
                alert.runModal()
            }
            restored = ok
            sender.reply(toApplicationShouldTerminate: ok)
        }
        return .terminateLater
    }
}
