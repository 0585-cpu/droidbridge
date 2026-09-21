import Foundation
import Observation
import DroidBridgeShared

/// @MainActor bridge between the shared `DroidBridgeCoordinatorCore` actor and SwiftUI. Publishes an
/// immutable `HostAppState` the views render; performs no protocol logic itself.
@MainActor
@Observable
public final class DroidBridgeCoordinatorAdapter {
    public private(set) var state: HostAppState = .idle
    public private(set) var pairedMacName: String?

    private let core: DroidBridgeCoordinatorCore
    private let devices: () async -> [AdbDevice]

    public init(core: DroidBridgeCoordinatorCore, devices: @escaping () async -> [AdbDevice]) {
        self.core = core
        self.devices = devices
    }

    public func refresh() async {
        await core.deviceSnapshotChanged(await devices())
        state = await core.state
    }

    public func disconnect() async {
        await core.disconnect()
        state = await core.state
    }
}
