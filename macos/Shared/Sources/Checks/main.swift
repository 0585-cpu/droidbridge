import DroidBridgeShared
import Foundation

let runner = CheckRunner()
runConfigurationChecks(runner)
await runAdbChecks(runner)
runner.finish("all")
exit(runner.failures == 0 ? 0 : 1)
