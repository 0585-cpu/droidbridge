import Foundation

/// Safe metrics for display and for the provider `metrics` message. Carries no destinations or payload.
public struct TunnelMetricsSnapshot: Codable, Equatable, Sendable {
    public let activeFlows: Int
    public let uploadedBytes: UInt64
    public let downloadedBytes: UInt64
    public let carrierName: String?
    public let cellularAvailable: Bool

    public init(activeFlows: Int, uploadedBytes: UInt64, downloadedBytes: UInt64,
                carrierName: String?, cellularAvailable: Bool) {
        self.activeFlows = activeFlows
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.carrierName = carrierName
        self.cellularAvailable = cellularAvailable
    }
}
