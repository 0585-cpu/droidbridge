import Foundation

/// Minimal blocking bridge so the assert-based Checks can drive async code deterministically.
func runBlocking(_ body: @escaping @Sendable () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}
