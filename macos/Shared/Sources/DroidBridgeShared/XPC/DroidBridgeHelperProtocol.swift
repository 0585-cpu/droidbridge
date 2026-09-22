import Foundation

/// XPC contract between the user app and the privileged helper.
///
/// Models cross the privilege boundary as encoded data so both processes can validate
/// them independently before changing tunnel state.
@objc public protocol DroidBridgeHelperProtocol {
    func installStatus(reply: @escaping (Bool) -> Void)
    func startTunnel(
        configJSON: Data,
        secret: Data,
        reply: @escaping (Bool, String?) -> Void
    )
    func status(reply: @escaping (Data) -> Void)
    func stopTunnel(reply: @escaping (Bool) -> Void)
}

/// Shared identifiers and peer code-signing requirement construction for helper XPC.
public enum HelperCodeRequirement {
    public static let machServiceName = "io.droidbridge.helper"

    public static func string(teamID: String, bundleID: String) -> String {
        "identifier \"\(bundleID)\" and anchor apple generic "
            + "and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
