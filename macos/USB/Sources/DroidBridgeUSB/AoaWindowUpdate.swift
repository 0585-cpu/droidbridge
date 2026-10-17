import Foundation

/// Mux-queue-owned cumulative WINDOW scheduling.
package struct AoaWindowUpdate {
    package init() {}
    private var advertised: UInt64 = 0
    package private(set) var deadline: TimeInterval?
    package mutating func consumed(_ total: UInt64, now: TimeInterval) -> Bool {
        guard total > advertised else { return false }
        if deadline == nil { deadline = now + 0.005 }
        return total - advertised >= 32768 || isDue(now)
    }
    package func isDue(_ now: TimeInterval) -> Bool { deadline.map { now >= $0 } ?? false }
    package mutating func sent(_ total: UInt64) {
        advertised = total
        deadline = nil
    }
}
