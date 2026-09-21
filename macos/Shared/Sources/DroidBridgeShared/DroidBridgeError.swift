import Foundation

/// Typed errors surfaced across the control plane. Messages are safe to show; they never carry secrets.
public enum DroidBridgeError: Error, Equatable, Sendable {
    case dataPlaneNotInstalled
    case invalidConfiguration(String)
    case adbNotFound
    case adbCommandFailed(exitCode: Int32, message: String)
    case adbTimedOut
    case forwardConflict(port: UInt16)
    case deviceUnauthorized(serial: String)
    case keychainFailure(status: Int32)
    case secretWrongLength
    case appGroupUnavailable
    case pairingFrameTooLarge
    case pairingProtocol(String)
    case pairingRejected
    case pairingTimedOut
    case pairingCancelled
    case relayProtocol(String)
    case relayAuthenticationFailed
    case relayTimedOut
    case cellularUnavailable
    case relayAppNotRunning
}
