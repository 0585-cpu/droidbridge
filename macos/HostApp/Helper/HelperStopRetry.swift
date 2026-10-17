import Foundation

/// XPC is expected to disconnect when the Stop watchdog replaces a wedged helper.
/// Retry only transport/deadline failures; an explicit restoration failure is actionable.
enum HelperStopRetry {
    static func run(timeout: Duration = .seconds(40), delay: Duration = .milliseconds(300),
                    attempt: () async throws -> Void) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while true {
            do { try await attempt(); return }
            catch HelperClientError.rejected(let message) { throw HelperClientError.rejected(message) }
            catch {
                guard ContinuousClock.now < deadline else { throw HelperClientError.timedOut }
                try await Task.sleep(for: delay)
            }
        }
    }
}
