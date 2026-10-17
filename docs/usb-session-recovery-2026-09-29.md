# USB session recovery — 2026-09-29

## Defects and scope

Android closed its accessory after a strict frame validation failure but never
reopened it. Mac retries could not recover that closed peer. The existing app
repeated this at 17:33:36 and 17:47:09 KST while the fix was being built. At
17:47:12 and 17:47:15, Mac also attempted consecutive writes on the failed USB
session, delaying failure handling. Neither sequence proves that phone use
caused the initial frame error.

The Mac serial writer now checks session retirement on the state queue before
each queued transfer. Once a write fails, later queued frames do not touch that
transport. Partial transfers are never replayed.

Android now owns explicit connection intent in a recovery controller. Unexpected
closure schedules at most three retries after 1, 2, and 4 seconds, within a
15-second recovery window. Simply reopening does not reset the budget; a session
must survive 30 seconds before a subsequent failure gets a fresh budget.
Presence and existing permission are rechecked around platform open. Stop and
detach cancel pending attempts and reject late callbacks/results. A returned
descriptor is owned immediately so Stop can close it during the final permission
check. A timed partial wake lock covers the recovery gap; each live descriptor
retains the existing session wake lock. Platform open cannot be forcibly
interrupted; late results are closed without starting a bridge.

Accessory comparisons use permission-independent descriptive fields and the
Android single-accessory/detach lifecycle. They never invoke `UsbAccessory.equals`
or `getSerial`, which can throw after permission is lost. Replacement bridges
still require a fresh RESET and existing authenticated DBP streams. Malformed
frames are still rejected; diagnostics distinguish invalid magic from invalid
version without recording any payload.

## Local verification

- Mac failed-write regression failed against the previous writer and passed
  after the stop gate was added. It uses real loopback delivery to queue credit
  frames behind a blocked DATA write, then verifies that none touch the failed
  transport.
- `make check-macos-usb`: passed, including packet boundaries, codec, queued-write
  failure, mux/half-close, Stop during open, occupied port, and handshake checks.
- Android full unit suite: 153 tests, zero failures/errors. USB subset: 24 tests
  including 14 recovery cases, two platform-adapter cases, and existing parser,
  bridge, and resource checks.
- Android lint: zero errors, 18 warnings; APK and instrumentation APK built.
- Mac Release build, development signature, and strict/deep signature checks
  passed. Installed privileged helper is retained unchanged (SHA-256
  `d70657262626194accd018739fd0a9d382bf9d21db7b10e568f19388de212022`).
- Independent read-only review found no actionable issues in the scoped Mac
  writer gate, Android recovery controller, adapter, and related tests.

## Device verification

Before replacement, normal Mac Stop restored the `en0` default route
and a verified HTTPS request returned 204. The GUI was then quit. The Android APK
was updated in place at 17:57:29 KST; installation returned Success. The signed
candidate Mac app was subsequently launched ready to connect, with Wi-Fi active.
On September 30 the user connected the phone and continued device validation.
The explicit
`USBChecks --recovery-probe <libusb-path> <accessory-location>` command is a
disruptive acceptance check, never run by normal unit checks: it establishes
RESET, sends one malformed header, releases USB, and verifies a fresh RESET
after Android automatic reopen. Run it only with the GUI stopped and an alternate
internet path active. Passing this probe establishes USB reopen, not internet
continuity or survival of old TCP streams.

Evidence: `build/evidence/2026-09-29-usb-session-recovery/`.

### September 30 connected-device observation

The running Mac app was `DerivedData-USBSessionRecovery/.../DroidBridge.app`
(PID 3432); Android's update time was September 29 17:57:29 (PID 22202).
The helper hash still matched the unchanged installed helper. The default route
was `utun5`, gateway `198.18.0.1`. Wi-Fi was powered off, so the disruptive
malformed-header probe was deferred to preserve the only working internet path.

Before observation, Android recorded a USB read EIO at 12:08:34.206 KST and
automatically opened a replacement at 12:08:35.212, after 1.006 seconds. Wake-lock
history confirmed transfer from the old session to the timed recovery lease and
then the new session. A subsequent explicit close at 12:08:37.384 and reopen at
12:08:40.559 mean these logs do not prove end-to-end automatic Mac recovery.
The initiating cause of that EIO is unknown.

At approximately 12:11:36, the user confirmed beginning web/video use on the
phone. From 12:11:24 to 12:16:24, a TLS-verified persistent HTTPS probe completed
30 successful requests, zero failures, and zero reconnections on the same TCP
local port (50611). Median response time was 263.5 ms; maximum was 535 ms.
A fresh HTTPS request afterward returned 204 in 1.696 seconds.

No Android session close/reopen or Mac USB session termination occurred during
the five-minute probe. Five USB OUT transfers were slow but successful
(921, 980, 1557, 1017, and 982 ms). Mac app, Android app, and helper processes
remained unchanged. This confirms concurrent phone use worked during the sampled
window; it does not establish absence of rarer disconnects or validate Codex's
own streaming protocol. Neither app nor network configuration was changed during
this observation. Evidence: `build/evidence/2026-09-30-usb-session-recovery/`.

Build artifacts:

- `build/artifacts/DroidBridge-usb-session-recovery-debug.apk`, SHA-256
  `fed5e4a7fbafa6f51a4d3c1f5b72ddbb910021c9228e4caea61e9c74b97da35c`.
- `build/artifacts/DroidBridge-usb-session-recovery-mac.zip`, SHA-256
  `60abe0aaf08108c154fdd2875a3f92bce73aee11156a0f45caddafba99db6ccd`.

## Remaining limitation

The trigger for the initial intermittent frame corruption remains unproven.
Existing TCP sessions cannot survive destruction of their USB session. Bounded
recovery reduces the need for manual reconnect; it does not promise zero drops.
