# Manual disconnect/reconnect investigation — 2026-09-29

## Report and observations (KST)

The user reported that pressing Disconnect then Connect on Mac or Android failed,
with Android displaying USB disconnected/an error. The previous five-minute
concurrent-use acceptance did not exercise Android service Stop/Start.

At 02:42:37 Android closed its USB bridge. Until a later successful service start
at 02:43:57, Mac RESET writes timed out. Mac-only Stop/Start subsequently succeeded
with HTTPS 204. Normal Mac Stop restored `en0`/the alternate network.

The user repeated Android Stop/Start at 02:46:38–02:46:44. Android received multiple
`CONNECT_USB` service intents but did not start a new USB bridge; service state was
empty. USB accessory mode and the physical cable remained configured. The exact
on-screen error from that interaction was not captured, so a matching code defect
must be distinguished from conclusive attribution of every reported failure.

## Reproduced defect and change

`RelayServer` previously bound its loopback TCP listener with address reuse
disabled. When the server closes an accepted connection first, the local port can
remain in TIME_WAIT. Immediate Stop/Start then throws `BindException`, before the
foreground service reaches USB setup. The startup catch stops the service, making
this look like a USB reconnect failure.

The new host unit regression uses the real relay: authenticated HEALTH response,
server EOF, Stop, and immediate Start on the same port. Before the change it failed
with `Address already in use`. An Android instrumentation regression, run against
the **previously installed APK before replacement**, also failed with
`bind failed: EADDRINUSE` in `RelayServer.start`. That test uses an invalid header
to make the real relay close first, and has no USB/cellular/pairing side effects.

The listener now sets SO_REUSEADDR before bind, still binds only `127.0.0.1`, and
closes a newly allocated socket if bind fails. A separate regression confirms a
second live listener cannot take the occupied port. Startup exceptions are now
logged to distinguish relay-start failures from USB-open failures. Authentication,
pairing credentials, USB timeout/recovery, and Mac network protection are unchanged.

## Verification and installation

- Android unit suite: 137 tests, zero failures/errors/skips.
- Android lint: zero errors, 18 existing warnings; debug APK built successfully.
- Android device regression: old installed APK failed; updated APK passed three
  consecutive start/connection/stop cycles on the same port.
- Independent review: no critical or important finding in this patch.
- APK installed with `adb install -r`, preserving app data and pairing.
- Mac app and privileged helper were not replaced.
- Actual phone button verification passed: the user reported no error and
  "공유 준비 완료". Android PID 9465 logged close at 03:05:42.895 and a new USB
  session at 03:05:44.150 (1.255 seconds later). The foreground service remained
  running, and Mac reconnect restored `utun5` with HTTPS 204 in 452 ms.
- A final Mac-only Stop/Start also passed with the updated APK. Stop restored
  `en0` and HTTPS 204 in 103 ms; Connect restored `utun5` and HTTPS 204. The
  connection was left running. See `button-acceptance.json` for the final timing.

These checks establish that the repaired immediate-rebind path and the tested
manual button sequence work. They do not test every possible USB failure or rapid
concurrent button ordering, nor do they change the bounded automatic-retry policy.

Artifact: `build/artifacts/DroidBridge-manual-reconnect-debug.apk`

SHA-256: `6a16e463d9d29b056fe22a3fa2f7dcc9eaad87ab113ad4f89aada766c07dc95b`

Raw test output and filtered diagnostics remain local under
`build/evidence/2026-09-29-manual-reconnect/`.
