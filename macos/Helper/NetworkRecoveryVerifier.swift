import DroidBridgeShared
import Foundation

/// Confirms only removal of DroidBridge's settings, never promises that an upstream
/// Wi-Fi/hotspot has internet. Other VPN services and global PF policy are preserved.
struct NetworkRecoveryVerifier {
    var run: HelperCommandExecuting = HelperCommandRunner.run
    var attempts: Int = 10
    var interval: TimeInterval = 0.1

    func verify(utun: String?) throws {
        try verifyRouting(utun: utun)
        try verifyAnchor()
    }

    func verifyRouting(utun: String?) throws {
        var lastError: Error = failure("network restoration could not be verified")
        for attempt in 0..<attempts {
            do { try checkRouting(utun: utun); return }
            catch { lastError = error }
            if attempt + 1 < attempts { Thread.sleep(forTimeInterval: interval) }
        }
        throw lastError
    }

    func verifyAnchor() throws {
        let answer = try command("/sbin/pfctl", ["-a", PfController.anchorName, "-s", "rules"])
        guard answer.standardOutput.isEmpty else { throw failure("DroidBridge firewall rules remain") }
    }

    private func checkRouting(utun: String?) throws {
        for family in ["IPv4", "IPv6", "DNS"] {
            let answer = try command("/usr/sbin/scutil", [], "show State:/Network/Service/\(TunnelNetworkService.serviceID)/\(family)\nquit\n")
            guard answer.outputText.trimmingCharacters(in: .whitespacesAndNewlines) == "No such key" else {
                throw failure("DroidBridge \(family) service remains")
            }
        }
        for query in [TunnelNetworkService.primaryQuery, TunnelNetworkService.primaryIPv6Query] {
            let answer = try command("/usr/sbin/scutil", [], query).outputText
            guard !answer.contains(TunnelNetworkService.serviceID),
                  utun == nil || TunnelNetworkService.primaryInterface(from: answer) != utun else {
                throw failure("DroidBridge is still the primary network")
            }
        }
        for arguments in [["-n", "get", "default"], ["-n", "get", "-inet6", "default"]] {
            let answer = try run(URL(fileURLWithPath: "/sbin/route"), arguments, nil)
            if answer.status != 0 {
                // Disconnected Wi-Fi/no IPv6 is a valid restored configuration.
                guard answer.outputText.contains("not in table") else { throw failure(answer.outputText) }
                continue
            }
            let values = answer.outputText.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let pair = line.split(separator: ":", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return pair[1].trimmingCharacters(in: .whitespaces)
            }
            guard !values.contains(TunnelNetworkService.gateway), !values.contains(TunnelNetworkService.ipv6Gateway),
                  utun == nil || !values.contains(utun!) else { throw failure("DroidBridge default route remains") }
        }
        let dns = try command("/usr/sbin/scutil", ["--dns"]).outputText
        let servers = dns.split(whereSeparator: \.isNewline).filter { $0.contains("nameserver[") }.compactMap { line in
            line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        }
        guard !servers.contains(TunnelNetworkService.gateway), !servers.contains(TunnelNetworkService.ipv6Gateway) else {
            throw failure("DroidBridge DNS resolver remains")
        }
    }

    private func command(_ path: String, _ arguments: [String], _ input: String? = nil) throws -> HelperCommandResult {
        let result = try run(URL(fileURLWithPath: path), arguments, input.map { Data($0.utf8) })
        guard result.status == 0 else { throw failure(result.outputText) }
        return result
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.droidbridge.network-recovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
