# Mac network outage after reconnect — 2026-09-28

## Incident

After the Android streaming fix was installed, the user reopened the phone app and the Mac Connect action displayed Connected at approximately 14:53 KST. Actual external connectivity had not yet been checked. The user subsequently reported loss of both DroidBridge and hotspot connectivity on the Mac, while the phone's own internet still worked.

The system CPU diagnostic at `/Library/Logs/DiagnosticReports/io.droidbridge.helper_2026-09-28-145442_<mac-host>.cpu_resource.diag` records 90 CPU seconds over 91 elapsed seconds (99%) in the helper from 14:53:10 to 14:54:41. Its sampled stack remains in `sys_timeout_abs` (`timeouts.c:214`) called by `sys_check_timeouts` and the `EngineBridge` timer. The Mac rebooted at 15:06:20. The retained recovery journal predates that boot.

On inspection after the reboot, the default route and DNS used the hotspot on `en0`, and a system-resolver HTTPS request returned 204. The Mac app still reported teardown failure. No further tunnel connection was attempted.

## Findings and fixes

`db_lwip_init()` called `lwip_init()` for every tunnel session. lwIP's memory pools are reset by that call, but its process-global timeout list and TCP timer scheduling flag are not reset. A regression requiring SYN-ACK retransmission across repeated sessions failed 18 assertions before the fix and passes afterward. The damaged timer lifecycle is consistent with the real helper's spin; the exact 91-second spin was not reproduced in the deterministic test.

The adapter now initializes lwIP once per process, rebases existing timers on a new session, and rejects overlapping live adapters. Shutdown retires remaining TCP PCBs (including graceful closing state), removes the netif, and clears clock/random callback owners. Tests cover repeated retransmission and payload delivery, active/FIN_WAIT cleanup, and real Swift timer restarts. The host must continue to serialize adapter calls.

The outage could block the alternate connection because DroidBridge's active PF rules reject physical-interface egress, while normal Stop waits synchronously for the engine queue. Fixing the timer lifecycle addresses the reproduced trigger. A separate administrator recovery command now restores network state without using the stalled engine process; this is an escape path, not a claim that arbitrary future engine hangs are impossible.

PF reference tokens belong to the running kernel. New recovery journals record the boot-session UUID; prior-boot tokens are ignored while the recovery journal remains until explicit Stop. Legacy journals older than the boot time receive the same handling. Current-boot tokens remain retryable. Apple's [PF reference implementation](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/net/pf_ioctl.c) returns errors for a stopped PF instance or an absent/mismatched token.

## Validation

- Core regression failed before the timer fix and passes afterward.
- Full core suite also passes AddressSanitizer and UndefinedBehaviorSanitizer.
- Helper checks: 13 passed, including prior-boot journal handling and real DispatchSource timer restarts; operation-lock check passed.
- macOS shared checks: 249 passed.
- Recovery script fixtures: 3 passed (success, recovery failure, partial bootstrap failure with previous-helper restoration). These fixtures do not change the actual system network.
- Signed Mac build and app/helper/libusb signature checks passed.
- Recovery script and helper recovery entry point reject execution without administrator privileges.
- Scoped independent review found a script rollback gap; it was fixed and the corresponding failure path now passes.

## Applying the prepared fix

Prepared archive: `build/artifacts/DroidBridge-network-recovery-mac.zip`.

The existing normal installer refuses to update while a recovery journal exists, so the dedicated recovery script is required for this incident:

```sh
sudo /bin/bash ~/.codex/worktrees/aoa-transport/droidbridge/scripts/recover-macos-network.sh
```

It validates a staged helper signed by the installed helper's team, acquires the existing operation lock, stops the registered DroidBridge helper, restores only DroidBridge's network service/PF anchor/reference, retains the previous helper as a rollback copy, and installs/starts the corrected helper. It leaves the USB tunnel stopped. Failures retain or restore the previous binary and recovery state as applicable. It never disables the global firewall or flushes other anchors.

The user manually ran the administrator command after Terminal automation was denied by the computer-use tool. Installation was then verified: the installed and built helper SHA-256 hashes match (`6537f6f77c22cd5518fb4eae0145cddca0c331d941231e811be462dcd3e70216`), launchd runs the new helper, its signature verifies, the recovery journal is gone, and the previous helper rollback copy exists. The Mac app's teardown-failed state cleared to the phone-disconnected state. Default route and DNS remain on the hotspot (`en0`), with HTTPS 204 in approximately 0.30 seconds. **Network recovery and helper installation passed; a live USB reconnect/Codex retest has not run.** The phone is currently disconnected and the tunnel remains stopped. Logs, artifact hashes, and regression evidence are in `build/evidence/2026-09-28-network-recovery/`.

The Android streaming APK remains installed with its prior three direct device checks passed. Those loopback checks did not cover this Mac engine restart failure and did not establish that Codex's reconnection issue was resolved.

## Follow-up: independent GUI Disconnect

The previously missing GUI recovery path is now implemented and tested; see [Disconnect recovery](disconnect-recovery-2026-09-28.md). This follow-up has a new signed helper and launchd restart policy. Its installation status is tracked separately from the earlier installed timer/reboot fix above.
