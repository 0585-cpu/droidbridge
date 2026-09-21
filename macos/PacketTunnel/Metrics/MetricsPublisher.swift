import Foundation
import DroidBridgeShared

/// Publishes safe metrics to the App Group so the HostApp can display them. Carries no destinations.
final class MetricsPublisher: @unchecked Sendable {
    private let appGroup: String
    init(appGroup: String = "group.io.droidbridge.shared") { self.appGroup = appGroup }

    func publish(_ snapshot: TunnelMetricsSnapshot) {
        guard let dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return }
        let url = dir.appendingPathComponent("tunnel-metrics.json")
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
