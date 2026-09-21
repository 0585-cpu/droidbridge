import SwiftUI

/// Menu-bar host app entry point. The full workflow UI is added in the coordinator task.
@main
struct DroidBridgeApp: App {
    var body: some Scene {
        MenuBarExtra("DroidBridge", systemImage: "cable.connector") {
            Text("DroidBridge")
        }
        .menuBarExtraStyle(.window)
    }
}
