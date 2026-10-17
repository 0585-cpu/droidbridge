# TCP upload, incomplete connection and initial USB wait fixes

Scope: the three defects approved on 2026-10-14; preserves the prior TCP half-close fixes. Evidence: `build/evidence/2026-10-14-flow-recovery/` (task baseline, exact patch, RED/GREEN logs and build hashes).

## Changes

- Credit the Mac TCP receive window only when the relay accepts bytes. Before-open, blocked and partial-send tails remain uncredited until drained; this prevents a conforming uploader from overflowing the 64 KiB queue.
- Reap unaccepted TCP flows once lwIP removes their child after a valid reset or timeout. Impose a wrap-safe 30-second outer deadline and abort any child before retiring its listener. Invalid resets stay subject to lwIP sequence checks. Balance the active count even if listener creation fails.
- Android waits for the first host HELLO while the accessory is attached. The initiating host, blocked raw write and stalled active delivery retain their 10-second deadlines; stop/detach still release the session through existing ownership logic.

## Validation

- RED: new tests reproduced premature receive-window credit, leaked handshake slots and late-HELLO failure before the fixes.
- GREEN: C packet-engine suite, including three complete upload windows with exact byte comparison, pre-open buffering, partial acceptance, valid/invalid RST, clock wrap, duplicate SYN and delayed timer polling.
- C AddressSanitizer/UndefinedBehaviorSanitizer suite passed.
- Android 218 tests, lint and debug APK/test APK build passed. Real loopback channel accepted a host after 11 seconds and exchanged bytes. Simulated five-minute wait passed; active-data timeout remains tested.
- The first full Android run had one existing UDP loopback receive timeout; the unchanged focused test and subsequent full 218-test run passed. This is recorded rather than excluded.
- Shared Swift 317 checks, Mac USB checks, helper checks and operation-lock check passed.
- Release Mac app/helper built in `build/DerivedData-FlowRecovery` with team ABCDE12345; strict app/helper signature verification passed. Artifact hashes are in `build-verification.json`.

## Deployment and device validation

Mac app installed at `/Applications/DroidBridge.app`, previous bundle retained in the evidence directory. Android APK update installed and on-device SHA-256 matches the built APK; pairing preference digest unchanged. Default route restored to Wi-Fi (`en0`) and HTTPS 200 verified before installation.

Privileged helper installation confirmed on 2026-10-14 at 16:37 KST: the installed file matches the signed embedded helper (`78bb639d…1dce`), and launchd runs the helper. The Mac connected successfully over `utun5` after the phone had waited from 16:36:35 until 16:38:42 (first verified HTTPS response). The same Android PID 18712 and original accessory session were retained, with no initial-handshake timeout or recovery exhaustion. Evidence: `late-host-acceptance.json` and its before/after logs.

Physical USB acceptance passed from 16:38:42 to 16:41:43 KST:

- HTTP request-side FIN before reading the response: 20/20 complete, hash-verified replies.
- Tor Browser file: 176,943,035 bytes, 84.35 seconds at an intentional 2 MiB/s cap, exit 0, no retry/resume. SHA-256 `4771ad39f84323e60c1966b270a743c9a23f437569aca36dbb93988919c1a7ae`.
- The same HTTPS TCP socket (`198.18.0.2:53115`) returned 19/19 HTTP 200 responses over three minutes; Android PID 18712 and USB route `utun5` remained unchanged.
- Phone USB logs for the current process contain no handshake timeout, transport stop or frame-reader stop markers. Current app/helper signatures verify strictly.

Acceptance artifacts: `usb-acceptance.json`, `usb-http-fin.json`, `usb-download.json`, `usb-keepalive.json` and `phone-post-acceptance.log`. USB connection was left active after validation.

The new upload-backpressure and abandoned-SYN cases were verified using the native packet-engine fixtures and sanitizers, not by injecting faults into the live phone. This bounded check does not establish long-term Parsec stability or carrier-network behavior.

Independent read-only review found no actionable issues in this task delta and ran both current C binaries successfully. Hardware detach behavior and wake-lock energy cost were not measured in that review.
