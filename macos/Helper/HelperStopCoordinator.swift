import OSLog
import Darwin
import Foundation

/// Separate from lifecycle/engine locks. Only authenticated explicit Stop calls arm this
/// watchdog. Its durable intent is replayed by a fresh launchd process after a forced exit.
final class HelperStopCoordinator: @unchecked Sendable {
    static let intentURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/io.droidbridge.stop.json")
    private let lock = NSLock()
    private let worker = DispatchQueue(label: "io.droidbridge.stop-worker")
    private let watchdog = DispatchQueue(label: "io.droidbridge.stop-watchdog", qos: .userInitiated)
    private let store: HelperRecoveryStateStore
    private let timeout: TimeInterval
    private let restart: @Sendable () -> Void
    private var active = false
    private var generation: UInt64 = 0
    private var replies: [Reply] = []

    private final class Reply: @unchecked Sendable {
        let call: (Bool) -> Void
        init(_ call: @escaping (Bool) -> Void) { self.call = call }
    }

    init(store: HelperRecoveryStateStore = HelperRecoveryStateStore(url: intentURL),
         timeout: TimeInterval = 8, restart: @escaping @Sendable () -> Void = { HelperCommandRunner.exitForRecovery() }) {
        self.store = store; self.timeout = timeout; self.restart = restart
    }

    var isPending: Bool { lock.withLock { active || store.hasPersistedState } }

    func request(work: @escaping @Sendable () throws -> Void, reply: @escaping (Bool) -> Void) {
        lock.lock()
        if active {
            replies.append(Reply(reply))
            lock.unlock()
            return
        }
        do {
            try store.save(HelperRecoveryState(utun: "explicit-stop", pfEnableToken: nil))
        } catch {
            lock.unlock()
            helperLog.error("could not persist explicit Stop: \(error.localizedDescription, privacy: .public)")
            reply(false)
            return
        }
        active = true
        generation &+= 1
        let current = generation
        replies = [Reply(reply)]
        lock.unlock()
        watchdog.asyncAfter(deadline: .now() + timeout) { [self] in
            lock.withLock {
                guard active, generation == current else { return }
                // Do not unwind frozen C state, release protection here, or run destructors.
                // launchd starts a new address space, which replays only the saved Stop.
                restart()
            }
        }
        worker.async { [self] in
            var success = false
            do { try work(); success = true }
            catch { helperLog.error("network restoration failed: \(error.localizedDescription, privacy: .public)") }
            lock.lock()
            if success {
                do { try store.remove() }
                catch { success = false }
            }
            active = false
            let completed = replies
            replies.removeAll()
            lock.unlock()
            completed.forEach { $0.call(success) }
        }
    }

    /// Called before accepting XPC in a new helper; no old engine exists here. Commands
    /// have their own deadlines. Failure retains intent and exposes a retry, not a restart loop.
    func resumeIfRequested(work: () throws -> Void) throws {
        guard store.hasPersistedState else { return }
        _ = try store.load() // Reject malformed/non-regular intent before acting.
        try work()
        try store.remove()
    }
}
