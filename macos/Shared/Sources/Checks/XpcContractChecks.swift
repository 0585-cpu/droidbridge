import DroidBridgeShared

func runXpcContractChecks(_ r: CheckRunner) {
    let requirement = HelperCodeRequirement.string(
        teamID: "ABCDE12345",
        bundleID: "io.droidbridge.macos"
    )
    r.check(requirement.contains("identifier \"io.droidbridge.macos\""), "pins app bundle identifier")
    r.check(requirement.contains("certificate leaf[subject.OU] = \"ABCDE12345\""), "pins team OU")
    r.check(requirement.contains("anchor apple generic"), "requires Apple signing anchor")
    r.check(HelperCodeRequirement.machServiceName == "io.droidbridge.helper", "uses helper Mach service")
    r.finish("xpc contract")
}

