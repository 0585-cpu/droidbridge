import DroidBridgeShared
import Foundation

let runner = CheckRunner()
runConfigurationChecks(runner)
await runAdbChecks(runner)
runStorageChecks(runner)
await runPairingChecks(runner)
await runRelayChecks(runner)
await runHostChecks(runner)
runRelayFlowChecks(runner)
runTunnelChecks(runner)
runUtunFramingChecks(runner)
runPfRouteChecks(runner)
runXpcContractChecks(runner)
runPacketSourceChecks(runner)
runVpnChecks(runner)
runner.finish("all")
exit(runner.failures == 0 ? 0 : 1)
