import DroidBridgeShared
import Foundation

/// Privileged XPC endpoint. Tunnel lifecycle bodies are filled by the helper assembly.
final class HelperService: NSObject, NSXPCListenerDelegate, DroidBridgeHelperProtocol {
    let peerRequirement: String

    init(teamID: String = "ABCDE12345", bundleID: String = "io.droidbridge.macos") {
        peerRequirement = HelperCodeRequirement.string(teamID: teamID, bundleID: bundleID)
        super.init()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        guard validate(connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: DroidBridgeHelperProtocol.self)
        connection.exportedObject = self
        connection.activate()
        return true
    }

    /// The listener enforces `peerRequirement` before this delegate is called. Reject
    /// connections that do not identify a live client process as an additional guard.
    func validate(_ connection: NSXPCConnection) -> Bool {
        connection.processIdentifier > 1
    }

    func installStatus(reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func startTunnel(
        configJSON: Data,
        secret: Data,
        reply: @escaping (Bool, String?) -> Void
    ) {
        reply(false, "tunnel assembly is not initialized")
    }

    func status(reply: @escaping (Data) -> Void) {
        reply(Data("{}".utf8))
    }

    func stopTunnel(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}

