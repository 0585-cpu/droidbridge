import Foundation

/// A TCP destination for OPEN_TCP. IPv4 carries a dotted-quad string; domain carries a hostname.
public enum OpenDestination: Sendable, Equatable {
    case ipv4(String, UInt16)
    case domain(String, UInt16)

    public var port: UInt16 {
        switch self {
        case .ipv4(_, let p), .domain(_, let p): return p
        }
    }

    public var host: String {
        switch self {
        case .ipv4(let h, _), .domain(let h, _): return h
        }
    }
}
