import Foundation

public struct RelayHealth: Equatable, Sendable {
    public let status: DbpHealthStatus
    public let activeSessions: Int
    public let maximumSessions: Int
    public let uploadedBytes: UInt64
    public let downloadedBytes: UInt64
    public let carrierName: String
    public init(status: DbpHealthStatus, activeSessions: Int, maximumSessions: Int, uploadedBytes: UInt64, downloadedBytes: UInt64, carrierName: String) {
        self.status = status; self.activeSessions = activeSessions; self.maximumSessions = maximumSessions
        self.uploadedBytes = uploadedBytes; self.downloadedBytes = downloadedBytes; self.carrierName = carrierName
    }
    public var isCellularReady: Bool { status == .ready }
}
