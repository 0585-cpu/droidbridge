# SMAppService Helper Registration Spike

## Scope

This spike establishes the build-time shape of the privileged DroidBridge helper and
the launchd metadata that the host app will register. It deliberately does not install
or launch a system daemon, change routes, or alter `pf` on a developer workstation.

## Result

- Helper label and Mach service: `io.droidbridge.helper`
- Helper executable: `DroidBridgeHelper`
- Minimum deployment target: macOS 14
- Registration strategy: **explicit administrator-authorized manual installation**
- Runtime registration result: **not attempted because the documented prerequisite is unavailable**

The helper target builds as a signed or unsigned macOS command-line executable. Its
spike entry point opens `com.apple.net.utun_control`, logs the resulting descriptor,
and remains alive. A successful root launch is identified by `uid=0` and a nonnegative
utun descriptor in unified logging.

The macOS SDK's `SMAppService.h` states that apps containing LaunchDaemons must be
notarized. The project's required free Apple Development certificate can sign this
helper (verified locally with Team ID `ABCDE12345`) but cannot produce the Developer ID
distribution credentials needed for notarization. Calling `register()` cannot satisfy
that documented prerequisite, so the spike does not mutate system launchd state merely
to observe the expected rejection.

Task 7 therefore consumes `useSMAppService = false`. Its install UI must perform an
explicit administrator-authorized copy to
`/Library/PrivilegedHelperTools/io.droidbridge.helper`, install the launchd plist in
`/Library/LaunchDaemons`, and bootstrap it only after showing the user exactly what will
change. It must surface copy/bootstrap errors verbatim and must never install silently.
The implemented path uses the standard macOS administrator authentication dialog via
`osascript`; the embedded helper is validated against its bundle/team requirement both
before authorization and again from the root-owned staging path. The Host app is
therefore distributed outside the App Sandbox.

## Runtime validation procedure

Runtime validation is intentionally outside automated builds because it changes
system-wide launchd state and requires administrator approval:

1. Build the signed app with `DROIDBRIDGE_DEVELOPMENT_TEAM` set.
2. Review and approve the app's manual helper installation prompt.
3. Confirm the executable and plist are root-owned and not group/world-writable.
4. Confirm `system/io.droidbridge.helper` exists in launchd.
5. Confirm the helper log shows `uid=0` and `utun open fd` with a nonnegative value.
6. Use the app's uninstall action and verify that launchd and both installed files are gone.

Until those steps have been performed on the target Mac, the manual install and utun
runtime path must be described as unverified.
