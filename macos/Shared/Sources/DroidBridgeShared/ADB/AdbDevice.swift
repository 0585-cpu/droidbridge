import Foundation

public struct AdbDevice: Equatable, Sendable, Identifiable {
    public enum State: String, Sendable { case authorized, unauthorized, offline, unknown }
    public let serial: String
    public let state: State
    public let model: String?
    public let transportId: String?
    public var id: String { serial }

    public init(serial: String, state: State, model: String? = nil, transportId: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.transportId = transportId
    }
}
