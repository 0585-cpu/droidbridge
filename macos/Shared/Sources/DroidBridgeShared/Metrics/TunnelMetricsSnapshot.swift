import Foundation

/// Safe metrics for display and for the provider `metrics` message. Carries no destinations or payload.
public struct TunnelMetricsSnapshot: Codable, Equatable, Sendable {
    public let activeFlows: Int
    public let uploadedBytes: UInt64
    public let downloadedBytes: UInt64
    public let carrierName: String?
    public let cellularAvailable: Bool
    /// True while the helper still owns utun/route/pf state, including a retained fail-closed
    /// rollback state that the user must be able to stop explicitly.
    public let tunnelActive: Bool

    public init(activeFlows: Int, uploadedBytes: UInt64, downloadedBytes: UInt64,
                carrierName: String?, cellularAvailable: Bool, tunnelActive: Bool? = nil) {
        self.activeFlows = activeFlows
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.carrierName = carrierName
        self.cellularAvailable = cellularAvailable
        self.tunnelActive = tunnelActive ?? cellularAvailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeFlows = try container.decode(Int.self, forKey: .activeFlows)
        uploadedBytes = try container.decode(UInt64.self, forKey: .uploadedBytes)
        downloadedBytes = try container.decode(UInt64.self, forKey: .downloadedBytes)
        carrierName = try container.decodeIfPresent(String.self, forKey: .carrierName)
        cellularAvailable = try container.decode(Bool.self, forKey: .cellularAvailable)
        tunnelActive = try container.decodeIfPresent(Bool.self, forKey: .tunnelActive)
            ?? cellularAvailable
    }
}
