import DroidBridgeShared
import Foundation

var runner = CheckRunner()
runConfigurationChecks(&runner)
runner.finish("all")
exit(runner.failures == 0 ? 0 : 1)
