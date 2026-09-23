import Darwin
import DroidBridgeShared
import Foundation

/// Points the system resolver at the tunnel's virtual DNS and restores each
/// service exactly as it was. Without this, name lookups keep going to the
/// DHCP server on the physical interface, which the pf kill-switch blocks, so
/// every hostname fails while IP literals still work.
final class DnsController {
    private static let networksetup = URL(fileURLWithPath: "/usr/sbin/networksetup")

    private let run: HelperCommandExecuting
    private var originals: [String: [String]]?

    init(run: @escaping HelperCommandExecuting = HelperCommandRunner.run) {
        self.run = run
    }

    var isConfigured: Bool { originals != nil }

    /// Reads, but does not change, the DNS of every service that can become
    /// primary. Refuses on anything unreadable so nothing is ever changed that
    /// could not be put back.
    func capture() throws -> [String: [String]] {
        let listing = try execute(["-listnetworkserviceorder"])
        let services = NetworkServiceOrderParser.servicesWithDevices(from: listing.outputText)
        guard !services.isEmpty else {
            throw failure(["-listnetworkserviceorder"], EINVAL, "no network service with an interface")
        }
        var captured: [String: [String]] = [:]
        for service in services {
            let arguments = ["-getdnsservers", service]
            let answer = try execute(arguments)
            guard let servers = DnsServerListParser.servers(from: answer.outputText) else {
                throw failure(arguments, EINVAL, "unrecognized DNS configuration: \(answer.outputText)")
            }
            captured[service] = servers
        }
        return captured
    }

    /// Records the originals before the first change, so a failure part-way
    /// through is still fully restorable.
    func apply(_ captured: [String: [String]]) throws {
        guard originals == nil else {
            throw failure([], EALREADY, "tunnel DNS is already applied")
        }
        originals = captured
        for service in captured.keys.sorted() {
            try execute(DnsCommandBuilder.pointAtTunnel(service: service))
        }
        flushResolverCache()
    }

    func adoptRecoveryState(_ captured: [String: [String]]) throws {
        guard captured.allSatisfy({ !$0.key.isEmpty && $0.value.allSatisfy(DnsServerListParser.isValidServer) })
        else {
            throw failure([], EINVAL, "invalid persisted DNS recovery state")
        }
        originals = captured
    }

    /// Restores every service, attempting all of them even if one fails, and
    /// keeps the originals on failure so Stop can be retried.
    func restore() throws {
        guard let captured = originals else { return }
        var firstError: Error?
        for service in captured.keys.sorted() {
            do {
                try execute(DnsCommandBuilder.restore(service: service, servers: captured[service] ?? []))
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        flushResolverCache()
        if let firstError { throw firstError }
        originals = nil
    }

    /// Best effort: a stale negative cache would only delay the switch.
    private func flushResolverCache() {
        _ = try? run(URL(fileURLWithPath: "/usr/bin/dscacheutil"), ["-flushcache"], nil)
        _ = try? run(URL(fileURLWithPath: "/usr/bin/killall"), ["-HUP", "mDNSResponder"], nil)
    }

    @discardableResult
    private func execute(_ arguments: [String]) throws -> HelperCommandResult {
        let result = try run(Self.networksetup, arguments, nil)
        guard result.status == 0 else {
            throw failure(arguments, result.status, result.outputText)
        }
        return result
    }

    private func failure(_ arguments: [String], _ status: Int32, _ output: String) -> HelperCommandError {
        .failed(executable: Self.networksetup.path, arguments: arguments, status: status, output: output)
    }
}
