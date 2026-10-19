import OSLog
import Darwin
import DroidBridgeShared
import Foundation

// Explicit administrator recovery for a stopped/crashed daemon. A separate process keeps
// a wedged packet-engine queue from preventing restoration of the physical network.
if Array(CommandLine.arguments.dropFirst()) == ["--recover-network"] {
    guard geteuid() == 0 else {
        FileHandle.standardError.write(Data("network recovery requires administrator privileges\n".utf8))
        exit(EXIT_FAILURE)
    }
    do {
        let installed = try HelperCommandRunner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                                   arguments: ["print", "system/io.droidbridge.helper"])
        guard installed.status != 0 else {
            FileHandle.standardError.write(Data("stop the installed helper before network recovery\n".utf8))
            exit(EXIT_FAILURE)
        }
        let recovery = HelperService(underlay: TailscaleUnderlayInterface())
        try recovery.reconcilePersistedState()
        var restored = false
        let completed = DispatchSemaphore(value: 0)
        recovery.stopTunnel { restored = $0; completed.signal() }
        completed.wait()
        guard restored else {
            FileHandle.standardError.write(Data("network recovery failed; recovery journal retained\n".utf8))
            exit(EXIT_FAILURE)
        }
        print("DroidBridge network state restored")
        exit(EXIT_SUCCESS)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

if Array(CommandLine.arguments.dropFirst()) == ["--selftest-signing-team"] {
    guard let teamID = RuntimeSigningIdentity.teamID() else {
        FileHandle.standardError.write(Data("missing signed team identity\n".utf8))
        exit(EXIT_FAILURE)
    }
    print(teamID)
    exit(EXIT_SUCCESS)
}

// Emits the exact ruleset the helper would load, so the kill-switch check
// exercises shipped code instead of a copy that can drift away from it.
if CommandLine.arguments.dropFirst().first == "--selftest-pf-rules" {
    let operands = Array(CommandLine.arguments.dropFirst(2))
    guard let utun = operands.first, operands.count > 1 else {
        FileHandle.standardError.write(Data("usage: --selftest-pf-rules <utun> <physical>...\n".utf8))
        exit(EXIT_FAILURE)
    }
    let physical = Array(operands.dropFirst())
    guard ([utun] + physical).allSatisfy(NetworkHardwarePortParser.isSafeInterfaceName) else {
        FileHandle.standardError.write(Data("invalid interface name\n".utf8))
        exit(EXIT_FAILURE)
    }
    print(PfRuleBuilder(utun: utun, physical: physical).anchorBody(), terminator: "")
    exit(EXIT_SUCCESS)
}

if Array(CommandLine.arguments.dropFirst()) == ["--selftest-utun"] {
    do {
        let device = try UtunDevice()
        try device.assignAddress()
        print(device.interfaceName)
        fflush(stdout)
        RunLoop.main.run()
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
}

let service = HelperService(underlay: TailscaleUnderlayInterface())
do {
    try service.reconcilePersistedState()
} catch {
    // Keep the endpoint available so the signed host can surface the problem
    // and explicitly retry Stop without silently dropping protection.
    helperLog.error("startup recovery retained protection: \(error.localizedDescription, privacy: .public)")
}
service.resumePendingStop()
service.clearPreviousBoot()
service.resumeOwnerWatch()
let listener = NSXPCListener(machServiceName: HelperCodeRequirement.machServiceName)
listener.setConnectionCodeSigningRequirement(service.peerRequirement)
listener.delegate = service
listener.activate()
RunLoop.main.run()
