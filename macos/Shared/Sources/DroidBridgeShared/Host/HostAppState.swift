import Foundation

/// Immutable snapshot rendered by the menu-bar app.
public enum HostAppState: Equatable, Sendable {
    case idle
    case deviceMissing
    case deviceUnauthorized(serial: String)
    case deviceSelectionRequired([AdbDevice])
    case deviceReady(AdbDevice)
    case pairing(sas: String?)
    case relayPreparing
    case relayReady(health: RelayHealth)
    case failed(String)

    public var statusText: String {
        switch self {
        case .idle: return "Waiting for an Android device"
        case .deviceMissing: return "No Android device connected"
        case .deviceUnauthorized(let serial): return "Authorize USB debugging on \(serial)"
        case .deviceSelectionRequired: return "Select which Android device to use"
        case .deviceReady(let device): return "Ready: \(device.model ?? device.serial)"
        case .pairing(let sas): return sas.map { "Confirm code \($0)" } ?? "Pairing…"
        case .relayPreparing: return "Preparing relay…"
        case .relayReady: return "Relay ready; start the tunnel when ready"
        case .failed(let message): return message
        }
    }
}
