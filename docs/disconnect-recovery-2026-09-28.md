# Explicit Disconnect recovery — 2026-09-28

## Behavior

An authenticated, explicit Stop persists a separate owner-only `io.droidbridge.stop.json` intent before acquiring the helper lifecycle lock. A dedicated watchdog queue allows 8 seconds for completion. A stuck engine/lifecycle forces exit status 75 without C destructors; registered child commands are killed first. launchd's `KeepAlive.SuccessfulExit=false` restarts the helper even if the host app closes. The replacement restores only when explicit Stop intent exists; an ordinary crash or relay loss retains fail-closed behavior.

Stop withdraws the fixed DroidBridge configd service, closes its utun, checks that its service/default-route/resolver state is absent, then clears only `com.apple/io.droidbridge`, releases its own PF reference, verifies an empty anchor, and clears the journals. Interface names loaded from old journals are not ownership evidence because another VPN can reuse them. A failed PF release is accepted only if a successful, recognized `pfctl -s References` listing proves that exact token absent. Unknown output or a failed query retains recovery intent.

Engine metrics are cached outside the packet-engine queue. Status uses a nonblocking lifecycle lock, and XPC status/Stop replies have deadlines. The host retries transport interruptions during helper replacement for up to 40 seconds (plus the final bounded attempt); a definite restoration failure is displayed immediately. Normal helper commands time out after 3 seconds. Recovery errors remain retryable.

The connection screen includes **네트워크 설정 복원** whenever a helper is installed and tunnel state is inactive/unknown, including an app reopened while the helper is stuck. Starting the tunnel with an uncertain XPC outcome conservatively leaves Disconnect available. Recovery progress and completion/failure appear directly on the connection page. Successful Stop confirms removal of DroidBridge settings, not upstream internet reachability. An old installed helper's Stop reply is not described as verified recovery.

## Evidence

- Helper checks: 18 groups pass, including a real child killed by the Stop watchdog, intent replay in a replacement instance, a child command killed before watchdog exit, command timeout, frozen-engine metrics, no fail-open without explicit intent, stale DNS retaining PF, PF-release crash-window retry, reused utun owned by another VPN, and bounded host retry.
- The frozen-engine metrics regression failed before caching. The orphan-child regression and absent-PF-token retry regression failed before their corresponding fixes.
- Shared checks: 249 pass.
- Python tools suite: 30 tests run, 5 skipped, no failures; recovery script fixtures cover success and both rollback failures, including restoration of the previous launchd plist.
- Signed release app/helper/libusb checks pass. Existing warnings remain in the dormant NetworkExtension target and captured pairing-secret code; no new compile errors.
- Independent review found startup-error visibility, app-reopen recovery access, already-released PF token, and reused interface ownership gaps; these are addressed. The reviewer also caught a reply-gate fallback, now fixed.
- Local UI accessibility confirms the recovery button is visible with the phone disconnected. Hotspot route remains `en0`; HTTPS 204 was checked during development.

Evidence directory: `build/evidence/2026-09-28-disconnect-recovery/`.
Artifact: `build/artifacts/DroidBridge-disconnect-recovery-mac.zip`.

## Installation and limits

Implementation, automated fault tests, signed build, and administrator installation are complete. The user ran the updated recovery script; installed helper SHA-256 matches the built helper (`83ffa059ce75b181e5514edb3bff0500072bb0d53b7f01ffa01277bfc0308c31`) and its signature verifies. launchd runs PID 6853 with `KeepAlive.SuccessfulExit=false`. Both recovery journals are absent and rollback copies of the helper and plist exist. Default route/DNS remain on the hotspot (`en0`, gateway/resolver `10.227.27.245`); HTTPS returned 204 in 0.295 seconds. The USB tunnel remains off. The command used was:

```sh
sudo /bin/bash ~/.codex/worktrees/aoa-transport/droidbridge/scripts/recover-macos-network.sh
```

The app cannot enter the administrator password. The live USB reconnect and short HTTPS check described below passed. Live USB fault injection, real launchd watchdog recovery, and a long-duration Codex streaming retest remain unperformed. The test subprocesses use fake network commands and require no root privileges. Kernel/filesystem/launchd failures can still prevent recovery; success is reported only after verification, and manual recovery remains available.

## Subsequent live USB connection

The user authorized connecting the phone. The first host attempt failed before route mutation with a Keychain read error (`DroidBridgeError.keychainFailure`, NSError code 4). Restarting the final built Mac app cleared the error; no pairing reset or secret deletion was performed. The app then displayed Connected with LG U+. Default route changed to `utun5` via `198.18.0.1`, and system DNS changed to the tunnel resolver. All six short HTTPS requests (Google and Cloudflare) succeeded in 0.169–0.334 seconds. The app remained connected and traffic counters advanced. The USB tunnel was left active at the user's request. This verifies basic connectivity, not long-duration Codex stability or forced-hang recovery. Evidence: `live-usb-connection.json` and `live-usb-https.json`.
