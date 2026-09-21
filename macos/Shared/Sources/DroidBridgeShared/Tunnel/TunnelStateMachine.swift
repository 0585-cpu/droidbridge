import Foundation

/// Fail-closed lifecycle for the Packet Tunnel. Pure: it emits effects the controller executes and never
/// removes network settings except on explicit stop. Reconnect backoff is 1, 2, 4 seconds (three tries),
/// then a persistent blocked state until the HostApp asks to reconnect or the user disconnects.
public struct TunnelStateMachine: Equatable, Sendable {
    public enum BlockReason: Equatable, Sendable { case relayUnavailable, cellularUnavailable }
    public enum State: Equatable, Sendable {
        case running
        case blocked(BlockReason)
        case reconnecting
        case persistentBlocked(BlockReason)
        case stopped
    }
    public enum Event: Equatable, Sendable {
        case relayLost
        case cellularLost
        case reconnectAttemptFailed
        case reconnectSucceeded
        case reconnectRequested   // HostApp message
        case wake
        case stop
    }
    public enum Effect: Equatable, Sendable {
        case closeAllFlows
        case dropPackets
        case resetEngine
        case scheduleReconnect(delaySeconds: Int)
        case resumeIngestion
        case reportConnected
        case removeNetworkSettings
        case revalidate
    }

    public private(set) var state: State
    private var retryCount = 0
    private let delays = [1, 2, 4]

    public init(state: State = .running) { self.state = state }

    public mutating func handle(_ event: Event) -> [Effect] {
        switch (state, event) {
        case (.stopped, _):
            return []

        case (_, .stop):
            state = .stopped
            return [.closeAllFlows, .removeNetworkSettings] // flows first, settings last

        case (.running, .relayLost):
            return enterBlocked(.relayUnavailable)
        case (.running, .cellularLost):
            return enterBlocked(.cellularUnavailable)

        case (.blocked, .reconnectAttemptFailed), (.reconnecting, .reconnectAttemptFailed):
            let reason = currentReason()
            if retryCount < delays.count {
                let delay = delays[retryCount]
                retryCount += 1
                state = .blocked(reason)
                return [.scheduleReconnect(delaySeconds: delay)]
            }
            state = .persistentBlocked(reason)
            return []

        case (.blocked, .reconnectSucceeded), (.reconnecting, .reconnectSucceeded):
            retryCount = 0
            state = .running
            return [.resetEngine, .resumeIngestion, .reportConnected]

        case (.persistentBlocked, .reconnectRequested):
            retryCount = 0
            state = .reconnecting
            return [.scheduleReconnect(delaySeconds: 0)]

        case (.blocked, .wake), (.persistentBlocked, .wake):
            return [.revalidate]

        default:
            return []
        }
    }

    private mutating func enterBlocked(_ reason: BlockReason) -> [Effect] {
        state = .blocked(reason)
        retryCount = 1                       // first backoff of 1s consumed here
        return [.closeAllFlows, .dropPackets, .scheduleReconnect(delaySeconds: delays[0])]
    }

    private func currentReason() -> BlockReason {
        switch state {
        case .blocked(let r), .persistentBlocked(let r): return r
        default: return .relayUnavailable
        }
    }
}
