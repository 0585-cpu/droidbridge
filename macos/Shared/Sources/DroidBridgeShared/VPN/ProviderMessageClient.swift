import Foundation

/// Compact JSON control messages between the HostApp and the provider. Responses are capped at 16 KiB
/// and never contain destinations or payload.
public enum ProviderMessage: Equatable, Sendable {
    case status
    case metrics
    case reconnect

    public var command: String {
        switch self {
        case .status: return "status"
        case .metrics: return "metrics"
        case .reconnect: return "reconnect"
        }
    }

    public func encoded() -> Data { Data("{\"cmd\":\"\(command)\"}".utf8) }

    public static func parse(_ data: Data) -> ProviderMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = object["cmd"] as? String else { return nil }
        switch cmd {
        case "status": return .status
        case "metrics": return .metrics
        case "reconnect": return .reconnect
        default: return nil
        }
    }
}

public enum ProviderResponse {
    public static let maxSize = 16 * 1024

    /// Encodes a metrics response, refusing anything over the 16 KiB cap.
    public static func encodeMetrics(_ snapshot: TunnelMetricsSnapshot) throws -> Data {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= maxSize else { throw DroidBridgeError.relayProtocol("response too large") }
        return data
    }
}
