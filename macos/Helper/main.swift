import DroidBridgeShared
import Foundation

let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperCodeRequirement.machServiceName)
listener.setConnectionCodeSigningRequirement(service.peerRequirement)
listener.delegate = service
listener.activate()
RunLoop.main.run()
