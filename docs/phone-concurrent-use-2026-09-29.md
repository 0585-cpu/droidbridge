# Phone web/video use and USB disconnection

## Reproduction

The user initially described a symptom experienced before the screen-off update.
With the updated Android app and Mac app connected, the user then opened and used
web/video apps on the phone for a controlled three-minute observation. No deliberate
USB interruption, app suspension, reinstall or route change was performed during
this observation.

All times KST on 2026-09-29:

| Time | Evidence |
| --- | --- |
| 02:16:11 | Mac starts a persistent HTTPS connection, local port 62654. |
| 02:16:29.944–31.445 | Phone logs an app-start OLAF restriction interval. No app-specific log proves DroidBridge was frozen. |
| 02:16:31.406 | Mac kernel reports endpoint 0x01 OUT timeout, zero bytes transferred. |
| 02:16:31.571 | DroidBridge logs USB write failure, libusb error -7; its AOA session closes. |
| 02:16:31.742 | The existing HTTPS request fails with `Remote end closed connection without response`. |
| 02:16:32.581 | Automatic USB reopen attempt 1 begins. |
| 02:16:32.590 | USB session restored. |
| 02:16:42 | Next probe succeeds using a new TCP connection, port 62751. |
| 02:19:10 | Observation finishes: 17 successful requests, one failure, one reconnection. |

The app's partial wake lock remained held, its foreground service remained active,
and no new Android app crash was recorded. The active cellular network was 185.
The direct failure is the 1,000-ms USB OUT deadline and session invalidation. The
evidence does **not** establish the precise reason the phone/USB endpoint was late.
The overlapping app-start restriction is a hypothesis, not proof of a Samsung
freezer fault or of the phone's video bandwidth causing the timeout.

This differs from the earlier screen-off acceptance: that ten-minute run had no
USB session loss, whereas this concurrent-use run reproduced a real failure.
Automatic recovery restores connectivity but cannot preserve existing TCP streams
after their AOA session has been destroyed, explaining why an application can still
show reconnecting even when the USB app quickly recovers.

## Candidate change and verification

The narrow comparison change raises one native USB OUT transfer's timeout from
1,000 to 2,500 ms. Reads, control transfers, heartbeat deadlines, authentication,
framing and fail-closed behavior are unchanged. There are no whole-frame retries:
a transfer error, including a partial timeout, still invalidates the session.
Slow (at least 500 ms) and failed writes now log requested size, result and elapsed
time without payload bytes. The new telemetry allows the real-phone comparison
to show whether writes exceeding the old deadline complete without a session loss.

The native boundary regression test uses the real `db_usb_write` wrapper with a
timed libusb substitute. A 1.5-second stall failed before the change and passes
after it. Persistent stalls remain bounded; partial timeouts are not replayed;
physical detach remains an immediate error. All existing USB checks and helper
recovery checks passed with the change. The per-transfer timeout is not an
end-to-end guarantee for the helper's separate three-second HEALTH request.
A frame can require two native transfers, so closing during a write can wait
approximately five seconds. Review found no critical or important issue in this
candidate. The test's 2.9-second wall-clock assertion may be sensitive to severe
host scheduling load; it does not verify an end-to-end HEALTH deadline.

**Installed and five-minute comparison passed:** release signing initially failed
because the old Mac development provisioning profile expired at 02:00:46 KST and
Xcode returned `No Accounts`. After the user signed in, the Release build passed
with a new profile valid through October 6, 02:31:45 KST. The unchanged, already
installed helper was retained in the app bundle and the outer app was re-signed
with the same identity and entitlements. Deep/strict signature and helper identity
checks passed; the bundled helper matches the installed helper byte for byte.

At 02:33–02:34 KST, normal Stop restored the Wi-Fi route (`en0`) and HTTPS 204
succeeded. The new Mac app was then launched and connected without re-pairing.
The USB route (`utun5`) and HTTPS 204 succeeded. Android PID remained 17063;
neither its APK nor the privileged helper was replaced.

The user confirmed starting phone web/video use again. The comparison ran from
02:35:23 to 02:40:23 KST (300 seconds), using one TLS-verified persistent HTTPS
connection with a request every ten seconds:

| Measurement | Before (3 minutes) | Updated Mac (5 minutes) |
| --- | --- | --- |
| Successful HTTPS requests | 17 | 30 |
| Failed requests | 1 | 0 |
| HTTPS reconnections | 1 | 0 |
| USB session loss/recovery | 1 | 0 |

The updated run retained local TCP port 64412 throughout. Request latency median
was 264.5 ms, maximum 507 ms. At 02:39:02 the new USB log recorded a 2,392-byte
OUT transfer completing successfully in 1,102 ms; another 16-byte transfer took
688 ms. Both completed in full, without losing the USB session or the persistent
HTTPS connection. The 1,102 ms observation is direct evidence that this version
completed a write whose measured duration exceeded the old one-second limit.
It is not a controlled replay proving exactly what the old binary would have
done for the same phone scheduling event.

At the end, the GUI remained connected, the default route remained `utun5`, and
Android PID 17063 still owned the foreground service and CPU wake lock. The
installed helper remained PID 12546 with one launch. Only local diagnostic
collectors were stopped; the user's USB internet connection was left running.

This provides device evidence for improved short-stall tolerance under concurrent
phone use. Five minutes cannot establish that every disconnect cause is fixed,
and this HTTPS probe is not a direct inspection of Codex's own connection. The
underlying reason for the phone/USB stall remains unproven. Stalls exceeding the
new bound can still end a session and require recovery.

Package: `build/artifacts/DroidBridge-usb-write-stall-mac.zip`
SHA-256: `de47eeacb95615246900cda9621c578f1ccb3b2ffe32cf28e8dbdb551e4dff45`

## Local evidence and separate historical finding

`build/evidence/2026-09-29-phone-concurrent-use/` holds the probe JSONL, reproduction
summary, Mac and phone timelines, native test red/green logs, helper checks, signing
diagnostics and the pre-change source snapshots. These diagnostics remain local.

The retained Android crash buffer also contains an older 09-28 18:02:36 crash:
`UsbAccessorySession.detached` calls `UsbAccessory.equals`, which reads the serial
after permission has been revoked and throws `SecurityException`. That is a
separate, still-present detach cleanup issue. It was not the failure in this
concurrent-use observation and is not included in this USB deadline patch.
