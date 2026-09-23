import Darwin
import DroidBridgeShared
import Foundation

/// Makes the tunnel the Mac's primary network by publishing it to configd,
/// which then owns the default route and the system resolver and keeps both on
/// utun across Wi-Fi/hotspot changes, DHCP renewals and wake.
final class NetworkServicePublisher {
    private static let scutil = URL(fileURLWithPath: "/usr/sbin/scutil")

    private let run: HelperCommandExecuting
    private let attempts: Int
    private let pollInterval: TimeInterval
    private(set) var isPublished = false

    init(
        run: @escaping HelperCommandExecuting = HelperCommandRunner.run,
        attempts: Int = 25,
        pollInterval: TimeInterval = 0.2
    ) {
        self.run = run
        self.attempts = attempts
        self.pollInterval = pollInterval
    }

    /// Returns only once configd reports `utun` as the primary interface.
    func publish(utun: String) throws {
        guard let script = TunnelNetworkService.publishScript(utun: utun) else {
            throw failure(EINVAL, "invalid tunnel interface name")
        }
        // Marked before the change so a partial publish is still withdrawn.
        isPublished = true
        try apply(script)
        for attempt in 0..<attempts {
            let answer = try query(TunnelNetworkService.primaryQuery)
            if TunnelNetworkService.primaryInterface(from: answer) == utun {
                let ipv6 = try query(TunnelNetworkService.primaryIPv6Query)
                if TunnelNetworkService.primaryInterface(from: ipv6) == utun { return }
            }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: pollInterval) }
        }
        throw failure(ETIMEDOUT, "configd did not make \(utun) the primary network")
    }

    /// Idempotent, so it doubles as crash recovery in a helper that never
    /// published anything itself.
    func withdraw() throws {
        try apply(TunnelNetworkService.removeScript, tolerating: "No such key")
        isPublished = false
    }

    /// scutil exits 0 even when configd refuses a write; a successful set or
    /// remove prints nothing, so any other output is the error.
    private func apply(_ script: String, tolerating benign: String? = nil) throws {
        let problems = try query(script)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != benign }
        guard problems.isEmpty else {
            throw failure(EPERM, problems.joined(separator: "; "))
        }
    }

    private func query(_ script: String) throws -> String {
        let result = try run(Self.scutil, [], Data(script.utf8))
        guard result.status == 0 else { throw failure(result.status, result.outputText) }
        return result.outputText
    }

    private func failure(_ status: Int32, _ output: String) -> HelperCommandError {
        .failed(executable: Self.scutil.path, arguments: [], status: status, output: output)
    }
}
