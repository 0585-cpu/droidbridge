import Foundation

public enum TunnelRuntimeStatus: String, Codable, Equatable, Sendable {
    case running
    case blockedRelay
    case blockedCellular
    case reconnecting
    case persistentBlockedRelay
    case persistentBlockedCellular
    case teardownFailed
    case stopped
}

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
    public let runtimeStatus: TunnelRuntimeStatus
    public let activeUDP: Int
    public let udpDrops: UInt64
    public let capabilities: RelayCapabilities?

    public init(activeFlows: Int, uploadedBytes: UInt64, downloadedBytes: UInt64,
                carrierName: String?, cellularAvailable: Bool, tunnelActive: Bool? = nil,
                runtimeStatus: TunnelRuntimeStatus? = nil, activeUDP: Int = 0, udpDrops: UInt64 = 0, capabilities: RelayCapabilities? = nil) {
        self.activeUDP = activeUDP; self.udpDrops = udpDrops; self.capabilities = capabilities
        self.activeFlows = activeFlows
        self.uploadedBytes = uploadedBytes
        self.downloadedBytes = downloadedBytes
        self.carrierName = carrierName
        self.cellularAvailable = cellularAvailable
        self.tunnelActive = tunnelActive ?? cellularAvailable
        self.runtimeStatus = runtimeStatus ?? (cellularAvailable ? .running : .stopped)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeUDP = try container.decodeIfPresent(Int.self, forKey: .activeUDP) ?? 0
        udpDrops = try container.decodeIfPresent(UInt64.self, forKey: .udpDrops) ?? 0
        capabilities = try container.decodeIfPresent(RelayCapabilities.self, forKey: .capabilities)
        activeFlows = try container.decode(Int.self, forKey: .activeFlows)
        uploadedBytes = try container.decode(UInt64.self, forKey: .uploadedBytes)
        downloadedBytes = try container.decode(UInt64.self, forKey: .downloadedBytes)
        carrierName = try container.decodeIfPresent(String.self, forKey: .carrierName)
        cellularAvailable = try container.decode(Bool.self, forKey: .cellularAvailable)
        tunnelActive = try container.decodeIfPresent(Bool.self, forKey: .tunnelActive)
            ?? cellularAvailable
        runtimeStatus = try container.decodeIfPresent(TunnelRuntimeStatus.self, forKey: .runtimeStatus)
            ?? (cellularAvailable ? .running : .stopped)
    }
}
