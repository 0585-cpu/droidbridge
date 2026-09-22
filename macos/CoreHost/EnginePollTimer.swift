import Foundation

/// Drives lwIP's NO_SYS timers on the packet-engine queue. Without this,
/// delayed ACK and retransmission timers never advance during quiet flows.
final class EnginePollTimer: @unchecked Sendable {
    private let queue: DispatchQueue
    private let interval: DispatchTimeInterval
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?

    init(
        queue: DispatchQueue,
        interval: DispatchTimeInterval = .milliseconds(100)
    ) {
        self.queue = queue
        self.interval = interval
    }

    func start(_ poll: @escaping @Sendable () -> Void) {
        lock.withLock {
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(10)
            )
            source.setEventHandler(handler: poll)
            timer = source
            source.activate()
        }
    }

    func stop() {
        let active = lock.withLock {
            let active = timer
            timer = nil
            return active
        }
        active?.cancel()
    }

    deinit { stop() }
}
