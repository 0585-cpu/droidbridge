# USB reconnect hardening — 2026-10-13

## Scope and diagnosis

The 16:45 Mac USB I/O failure is still unexplained. The physical disconnect was recorded later, at 16:46; it does not establish the cause of the initial failure.

The stuck reconnect was reproduced with Android reporting `sec_charging,adb` while retaining a stale accessory entry. The old app could open `/dev/usb_accessory` in that state and prevent a fresh AOA transition. Stopping the app released the descriptor and restored AOA negotiation. The previous Mac trace rotation could also discard the original failure after repeated immediate reopen failures.

## Changes

- Gate Android accessory opens on the latest system USB state: connected, configured, and accessory mode. Recheck during resource acquisition; release ownership when accessory mode ends. Continue an already requested connection after valid AOA mode returns.
- Apply the reliable-link initial HELLO timeout on Android as well as Mac. Keep the existing bounded retry policy. The timeout does not expire an established link while the user is comparing pairing codes.
- Propagate transport closure to resource recovery even if the reader is blocked. Capture the last validated frame and a synchronized, payload-free read history once.
- Keep established-session failure traces separately from normal and zero-byte reopen traces. Record the first transport failure, excluding intentional shutdown errors.
- Treat a different AOA port as an authentication candidate. Authenticate with the existing pairing secret before updating the saved port. Failed authentication leaves the old configuration intact.

## Automated verification

- Android: 214 unit tests, zero failures/errors/skips; lint and both debug APK builds passed.
- Mac shared checks: 307 passed; full USB checks passed.
- Signed Release build, installed app signature, and installed helper signature verified.
- Added coverage for stale accessory lists, mode changes during open, initial handshake timeout, retained approval waits, diagnostic callback ordering, concurrent trace snapshots, trace retention, and authenticated port changes.
- A pre-existing duplex test intermittently stopped its simulated host after enqueueing the final payload. The fixture now waits for its final cumulative ACK so it continues servicing retransmissions. The full suite passed after that fixture correction.

## Device verification

Device: SM-F966N, Android 16. Evidence: `build/evidence/2026-10-13-usb-lifecycle-fix/`.

- Updated the APK without uninstalling; pairing preference digest remained identical.
- Updated `/Applications/DroidBridge.app` and the signed helper.
- Charging-mode transition retained stale accessory metadata but left no open `/dev/usb_accessory` descriptor. The ADB command connection ended during USB re-enumeration; the resulting `sec_charging,adb` state was independently confirmed.
- The Mac Connect button restored `accessory,adb` and USB HTTPS 200 without restarting the Android process or re-pairing.
- User physically moved the cable from USB `0-1` to `1-1`. The existing pairing authenticated successfully; the Android process and pairing digest were unchanged. USB HTTPS returned 200 from `198.18.0.2`.
- Initial HELLO timeout and subsequent descriptor reopen were observed on the real phone before the Mac connected.
- Tor Browser 15.0.25 downloaded over both IPv6 and IPv4 through the USB tunnel, without retry/resume. Each transfer was 176,943,035 bytes in approximately 84.35 seconds, deliberately limited to 2 MiB/s. Both matched the official SHA-256 `4771ad39f84323e60c1966b270a743c9a23f437569aca36dbb93988919c1a7ae`.
- A certificate-verified HTTPS connection remained on the same USB source port for 19 successful requests over three minutes before the concurrent-use interval.

Final download and sustained-use results are recorded separately in the evidence directory. Two test-harness issues were kept as failed-attempt evidence: the old Tor URL returned HTTP 404, and the first Python HTTPS probe lacked a local CA bundle. The current probe uses the system CA file with certificate verification enabled.

### Interrupted concurrent-use interval

The first concurrent-use run is **not a pass**: the persistent HTTPS connection returned `Broken pipe` at 18:01:07. Mac retransmissions increased from 18:00:46, capability/health probes timed out, and the helper retired flows at 18:01:05. Parsec recorded a simultaneous connection reset. The user subsequently confirmed cable movement/disconnection during that interval. Keep this as an interrupted test, not evidence of an unexplained spontaneous failure.

At 21:49 the phone was connected through another port, `2-1`, and the authenticated saved configuration was `aoa:2-1`. A new bounded observation began at 21:51:51. The gap between runs was not continuously monitored and must not be reported as hours of verified uptime.

### Final bounded observation

- 21:51:51–21:54:52: 19/19 HTTPS 200 responses on one USB source socket, with no USB retransmission/failure records in the captured interval.
- 21:54:30–21:55:31: 7/7 HTTPS 200 responses on one socket while Android reported `Dozing` and retained the USB CPU wake lock on every sample. No USB retransmission/failure records were captured.
- Parsec logged successful connection at 21:48:44 and no subsequent error/disconnect in the inspected log through this check.
- Android PID remained 26994 and the pairing digest remained identical. The final USB state was `accessory,adb`; the Mac app displayed connected.
- These are short verification intervals, not a long-duration stability guarantee. Aggregate evidence is in `final-verification.json`.

## Limits

This change addresses stuck reconnects and port-dependent pairing behavior. It does not establish the cause of the original USB I/O error or prove that all long-running Parsec disconnections are eliminated.
