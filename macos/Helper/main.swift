import Darwin
import DroidBridgeShared
import Foundation

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

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperCodeRequirement.machServiceName)
listener.setConnectionCodeSigningRequirement(service.peerRequirement)
listener.delegate = service
listener.activate()
RunLoop.main.run()
