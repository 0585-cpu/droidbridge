import Foundation

/// Keeps privileged route mutation behind a fresh, authenticated relay preflight.
@MainActor
struct TunnelStartupSequence {
    let installHelper: @MainActor () async throws -> Void
    let prepareRelay: @MainActor () async throws -> Void
    let startTunnel: @MainActor () async throws -> Void

    func run() async throws {
        try await installHelper()
        try await prepareRelay()
        try await startTunnel()
    }
}
