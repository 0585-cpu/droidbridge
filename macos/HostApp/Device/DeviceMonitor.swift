import Foundation
import DroidBridgeShared

/// Polls `adb devices` on an interval and yields snapshots. USB has no push events, so a short poll is
/// the pragmatic choice for B1.
public struct DeviceMonitor: Sendable {
    private let adb: AdbClient
    private let interval: Duration

    public init(adb: AdbClient, interval: Duration = .seconds(2)) {
        self.adb = adb
        self.interval = interval
    }

    public func snapshots() -> AsyncStream<[AdbDevice]> {
        AsyncStream { continuation in
            let task = Task {
                while !Task.isCancelled {
                    let devices = (try? await adb.devices()) ?? []
                    continuation.yield(devices)
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
