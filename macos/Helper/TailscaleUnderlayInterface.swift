import OSLog
import Foundation

/// Lets Tailscale run on top of the tunnel. On macOS Tailscale ignores every `utun*` interface
/// when deciding whether the Mac is online (net/netmon isInterestingInterface), so with
/// DroidBridge as the only network it stays paused. One address on a non-utun interface, with
/// no route through it, is enough for it to start; its sockets then follow the only default
/// route, which is the tunnel. Best effort: it never fails or blocks a tunnel start or stop.
final class TailscaleUnderlayInterface {
    static let name = "bridge9"
    static let address = "192.0.2.1" // TEST-NET-1: never a real destination
    private static let ifconfig = URL(fileURLWithPath: "/sbin/ifconfig")
    private let run: HelperCommandExecuting

    init(run: @escaping HelperCommandExecuting = HelperCommandRunner.run) {
        self.run = run
    }

    func create() {
        destroy() // a killed helper or a manual test may have left one behind
        guard attempt([Self.name, "create"]) else { return }
        _ = attempt([Self.name, "inet", Self.address, "netmask", "255.255.255.255", "up"])
    }

    func destroy() {
        _ = try? run(Self.ifconfig, [Self.name, "destroy"], nil) // absent is fine
    }

    private func attempt(_ arguments: [String]) -> Bool {
        do {
            let result = try run(Self.ifconfig, arguments, nil)
            if result.status == 0 { return true }
            helperLog.error("Tailscale interface \(arguments.joined(separator: " "), privacy: .public) failed: \(result.outputText, privacy: .public)")
        } catch {
            helperLog.error("Tailscale interface \(arguments.joined(separator: " "), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }
}
