# USB session interruption, 2026-09-28

All times below are KST (UTC+09:00). This investigation was read-only with respect
to the running app, phone, and network configuration. No fix was installed and no
deliberate disconnect or failure injection was performed.

## Findings

The evidence strongly supports a USB OUT transfer timeout as the immediate
trigger for the AOA session closing. It does not establish why the phone/USB path
stopped completing transfers promptly.

| Time | Observed evidence |
| --- | --- |
| 17:24:08.786–17:24:09.612 | macOS IOUSBHostFamily reports repeated zero-byte read timeouts on the Samsung device's endpoint 0x81. These read timeouts alone are tolerated by the transport. |
| 17:24:09.645 | macOS reports endpoint 0x01 (host-to-phone) timeout, status 0xe00002d6, zero bytes transferred. |
| 17:24:09.645–.646 | DroidBridge PID 7743 cancels both local AOA service listeners, 127.0.0.1:27183 and :27184, and closes the associated connections. |
| 17:26:48.654–.802 | Mac AppKit records user actions. The user separately confirmed that manual reconnection was necessary. |
| 17:26:48.812 | New local service listeners become ready. |

The source provides a matching failure path:

- `macos/USB/Sources/CAoaUSB/CAoaUSB.c:157`: USB writes have a 1,000 ms timeout;
  any transfer error is propagated. A failed partial write must invalidate the
  framed session rather than blindly resending an entire frame.
- `macos/USB/Sources/DroidBridgeUSB/LibusbAccessoryTransport.swift`: negative
  write results throw an AOA USB error.
- `macos/USB/Sources/DroidBridgeUSB/AoaMultiplexer.swift:233`: a writer error
  invokes `fail`, which closes both listeners, every stream, and the transport.
- `macos/HostApp/App/AoaDeviceLink.swift:37`: a stopped multiplexer is replaced
  when forwarding is prepared again. There is no automatic USB reopen on the
  disconnect callback; this caller uses the default no-op callback, so the exact
  failure message is also not persisted here.
- The helper's health monitor retries requests against the local relay endpoint;
  it cannot recreate a closed app-owned USB multiplexer by itself.

## Checks and limits

- Android USB event history contains no physical detach/re-enumeration at the
  incident time. Its last configured/accessory handshake was at 16:59:58.
- Android app PID 23503 remained present. No app crash was found in its retained
  logs around the incident.
- Helper PID 6853 was still running, with launchd `runs = 1` and no prior exit.
- Android's current cellular network is still network 185. The retained records
  do not establish a cellular loss at the incident time, nor exclude every short
  radio disturbance.
- Subsequent UI inspection showed Connected / LG U+. The default route remained
  198.18.0.1 through utun5.
- Subsequent HTTPS probes returned Google 204 in 0.392 s and Cloudflare 200 in
  0.246 s. This verifies current basic connectivity, not long-stream stability.
- The evidence does not support attributing this incident to carrier tethering
  detection. The precise source of the USB delay remains unconfirmed: phone-side
  processing, host scheduling, or USB transport conditions require more telemetry.

## Follow-up indicated by the evidence

Persist structured AOA disconnect reasons, transfer results and durations, and
phone reader/writer lifecycle events. Add bounded automatic AOA session reopening
while retaining fail-closed routing, so users do not have to press reconnect after
a recoverable transport failure. Evaluate USB write deadlines and backpressure
using those measurements; merely increasing the timeout would not establish or
fix the underlying cause. Existing TCP connections may still require application
reconnection after an AOA session is lost.

## Local evidence

`build/evidence/2026-09-28-transient-disconnect/` contains:

- `mac-usb-incident.log`: narrowly scoped USB/kernel events at the failure time.
- `timeline-excerpt.log`: listener shutdown/reopen and reconnect UI actions.
- `mac-app.log`: retained Mac app/helper unified logs for approximately 17:09–17:29.
- `android-app.log`, `android-usb.txt`, `android-connectivity.txt`, and
  `android-system.log`: phone diagnostics. These are local diagnostic records and
  have not been uploaded.

## Follow-up: screen-off correlation

The user asked whether switching the phone screen off could be related. The
phone's power event history confirms this sequence (KST):

- 17:21:23.151: screen OFF, reason `power_button`.
- 17:24:09.645: USB OUT timeout and Mac AOA listener shutdown, approximately
  2 minutes 46 seconds after screen-off.
- 17:26:28.199: screen ON, reason `power_button`.
- 17:26:48.812: Mac AOA service listeners ready following manual reconnect.

The Android implementation runs a connected-device foreground service, but the
manifest does not declare `WAKE_LOCK` and the app has no explicit CPU wake-lock
management. A subsequent service snapshot confirms the service is foreground.
Foreground service status alone does not guarantee that the CPU remains awake
with the screen off, as explained in Android's
[awake-state guidance](https://developer.android.com/develop/background-work/background-tasks/awake).

This makes screen-off suspend/power management a plausible upstream cause of the
USB delay, not a proven cause. No CPU suspend trace was captured at the failure.
The subsequent snapshot reports USB power/charging and DeviceIdle ACTIVE;
standard Doze must not be asserted from a screen-off event alone. See
[Doze prerequisites](https://developer.android.com/training/monitoring-device-state/doze-standby).

A controlled screen-on/screen-off comparison with USB I/O and suspend telemetry
is needed to confirm causality. If explicit CPU retention is required, scope it
to the active USB relay lifetime and release it on stop, detach, and failure;
also handle USB session recovery separately. No wake-lock change, battery-setting
change, forced idle, or screen toggle was performed during this investigation.

Additional evidence files: `android-power-state.txt`, `android-power-events.log`,
`android-idle-state.txt`, and `android-service-state.txt` in the same directory.

The subsequent CPU-retention and bounded USB-recovery implementation is described
in [the 2026-09-29 hardening report](screen-off-recovery-2026-09-29.md). The findings
above describe the version running at the incident; the update now has a ten-minute screen-off hardware check and a separate
USB session-recovery check. Those results do not establish the earlier root cause.
