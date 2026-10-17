# Screen-off and USB session recovery hardening

Implemented, built and installed on 2026-09-29 KST after the user confirmed an
alternate internet connection. The APK was updated in place and the Mac app and
helper were replaced with the signed build. The phone reconnected with its existing
pairing. The ten-minute screen-off observation and a separate USB session recovery test
both passed. The final state is Connected / LG U+ with the USB internet route active.

## Behavior

- Android owns a `PARTIAL_WAKE_LOCK` alongside the open USB accessory descriptor.
  It keeps CPU work eligible with the screen off without lighting the screen.
  Android Stop, accessory detach, bridge failure, service destruction, and failed
  session startup release the owner. Repeated close and late cleanup from an old
  session cannot release a replacement session's lock.
- The lock follows the **open Android accessory session**, including idle time
  while it waits for a host RESET. A Mac tunnel Stop by itself does not close the
  phone's USB descriptor. There is deliberately no elapsed-time expiry that would
  silently suspend a long-running connection; Android Stop or cable removal ends
  that lifetime. Lint reports `WakelockTimeout` for this intentional choice.
- After an established relay's AOA session fails, the Mac retries opening an
  accessory at the same selected USB location with 1/2/4-second backoff, at most
  three attempts. Those are delays before attempts, not a seven-second recovery
  guarantee: an individual handshake can still wait up to its existing deadline.
  Pairing alone does not enable retries. A new port or non-accessory device needs
  the ordinary connection flow.
- Session IDs and generations reject stale callbacks. Explicit Stop cancels
  retries and pending opens. A USB descriptor returned by a slow factory after
  Stop is closed immediately rather than leaked.
- Once USB is restored, the GUI requests an authenticated helper HEALTH recheck
  when necessary. The helper remains the owner of the engine, routes and PF.
  Automatic USB recovery never releases network protection. A redundant reconnect
  after health has already recovered is a successful no-op under the state lock,
  retaining the running engine and its monitor. A late XPC response cannot restore
  stale failure text after Stop.
- Mac `io.droidbridge` / `USBRecovery` logs retain the disconnect reason and retry
  outcome. Android `DroidBridgeUSB` logs record session start and termination.
  Raw transfer duration telemetry has not been added.

This mitigates the screen-off hypothesis and the observed need for manual USB
reconnection. It does not prove that CPU suspension caused the incident recorded
in [the diagnosis](transient-disconnect-2026-09-28.md). Fatal phone-side descriptor
loss may still require reopening DroidBridge. Existing TCP/QUIC sessions are not
migrated across USB session loss; a streaming application may have to reconnect.

## Verification

| Check | Result |
| --- | --- |
| Android unit tests | 135 passed, zero failures/errors/skips |
| Android lint / debug APK | Build passed; zero lint errors, 18 warnings, including the lifecycle-scoped wake lock's timeout warning |
| Shared Swift checks | 249 passed |
| USB checks | Codec, packet boundaries, real loopback, 256-KiB bidirectional transfer/half-close, occupied port, handshake, Stop-during-open cleanup passed |
| Helper checks | Existing 18 check groups plus AOA reopen/retry/Stop/isolation checks and stale-status reconnect regression passed |
| Regression evidence | Stop-during-open leaked transport and stale reconnect tests failed before their respective fixes, then passed |
| macOS Release build | Signed build succeeded using team `ABCDE12345`; strict app/helper signature verification passed |
| Production test isolation | Release helper symbols contain neither test state seed nor test health-generation accessor |
| Independent code review | The two identified recovery races were fixed and rechecked; no remaining Critical/Important finding in this scope |
| Working-tree whitespace | `git diff --check` passed |

Evidence is local in `build/evidence/2026-09-28-screen-off-recovery/` (the folder
was named when the investigation started). Baselines there distinguish this work
from earlier uncommitted UI/network recovery changes. Android tests use
Robolectric, and the helper tests use an injected health probe and test-only state
fixture; they do not open a real utun or contact the active phone.

Before deployment, the original helper remained SHA-256
`83ffa059ce75b181e5514edb3bff0500072bb0d53b7f01ffa01277bfc0308c31`, PID 6853.
After user authorization, explicit Stop restored Wi-Fi via en0 and a Google HTTPS
probe returned 204. The APK was updated with `adb install -r`; its installed bytes
match the prepared APK. The new Mac app runs from the separate build directory.
The user installed the new helper (PID 12546), matching the embedded SHA-256
`d70657262626194accd018739fd0a9d382bf9d21db7b10e568f19388de212022`.
USB connectivity resumed through utun5 and Android power diagnostics confirm
`DroidBridge:UsbRelay` held by the foreground app (PID 17063).

## Artifacts and hardware acceptance

- `build/artifacts/DroidBridge-screen-off-recovery-debug.apk`
- `build/artifacts/DroidBridge-screen-off-recovery-mac.zip`
- `build/artifacts/SCREEN-OFF-RECOVERY-SHA256SUMS.txt`
- Unpacked signed app: `build/DerivedData-ScreenOffRecovery/Build/Products/Release/DroidBridge.app`

The new app contains a changed helper, which was deployed too. The prior
`build/DerivedData/` app is preserved as a fallback. The recovery
script accepts the new helper path as its first argument (its default still
points to the older live build). Administrator authorization is required for that
installation. The APK was updated in place to preserve pairing.

Hardware results on Samsung SM-F966N / Android 16, all times KST:

- **02:00:03–02:10:03, screen off:** 600 seconds, 59 HTTPS HEAD requests over one
  persistent TLS/TCP connection to `www.cloudflare.com/`; 59 returned HTTP 200,
  zero failures and zero reconnects. Median latency 259 ms, maximum 413 ms,
  local TCP port 61345 throughout. The preceding 60-second smoke check also
  completed six requests without reconnecting.
- Android power snapshots before/after the 10-minute run show the same
  `mLastSleepTime` and `mLastWakeTime`, `mWakefulness=Dozing`, and the same held
  `DroidBridge:UsbRelay` partial wake lock. `mDeviceIdleMode=false`; this is not
  a forced standard-Doze test. No adb calls or screen manipulation were made
  during the 10-minute observation. No Android USB termination or Mac USB recovery
  event appeared during that interval.
- Explicit Mac Stop restored Wi-Fi via en0, with HTTPS 204 success. The app then
  prepared its USB relay without starting the network tunnel.
- **02:11:16.916–02:11:28.921:** the Mac app alone was deliberately paused for
  12 seconds while Wi-Fi carried internet traffic. On resumption, the real AOA
  heartbeat failure appeared at 02:11:28.922. Automatic attempt 1 began at
  02:11:29.937 and restored the USB session at 02:11:29.943 (1.021 seconds after
  the failure). The phone remained untouched. This exercises hardware session
  reopen, not physical unplug/replug or active-tunnel recovery.
- The normal Connect action then reauthenticated the phone and started the helper
  tunnel. The app returned to Connected / LG U+, default route utun5. Fresh Google
  and Cloudflare HTTPS requests returned 204/200. The helper did not restart during
  the test (PID 12546, launchd runs 1).

Evidence: `build/evidence/2026-09-29-screen-off-device/`. `screen-off-summary.json`
contains results; `mac-usb-fault-recovery.log` contains the actual retry timeline.
The initial Python probe setup failed because that Python had no CA store; it was
changed to use the Mac system root certificates with verification enabled. A HEAD
request to the initial `/cdn-cgi/trace` path returned 404, so the final probe uses
`/`. Those two setup logs are retained and are not counted as DroidBridge network
failures or successful acceptance runs.

Remaining limits: this is one phone/cable and a ten-minute observation, not proof
of the previous incident's root cause or all-day Codex stream stability. The test
uses periodic HTTP/1.1 requests on one TLS connection, not an actual Codex SSE or
WebSocket stream. Recovery of an actively routed tunnel under a real USB fault,
phone-side fatal descriptor loss, physical detach, long idle/battery effects,
and real-device wake-lock release on Android Stop remain outside this acceptance.
Automated lifecycle tests cover close, replacement, retry bounds and Stop races.
