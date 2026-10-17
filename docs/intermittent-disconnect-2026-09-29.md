# Intermittent USB disconnect inspection — 2026-09-29 afternoon

All times are KST. The user reported occasional disconnections and confirmed that
DroidBridge's connection state itself changed to disconnected. This inspection
leaves the current tunnel, installed apps, and helper running without replacement.

## Confirmed timeline

| Time | Evidence |
| --- | --- |
| 17:11:50.310 | Mac USB OUT of 16 bytes fails with libusb error -7 after 2,807 ms. Kernel reports endpoint 0x01 timeout with zero bytes transferred. |
| 17:11:50.654 | Mac ends the AOA session. |
| 17:11:51.792 | First automatic retry restores the USB session, 1.138 seconds after session termination. This log alone does not prove immediate restoration of internet traffic. |
| 17:15:21.675 | Android PID 9465 closes its bridge with `invalid AOA version`. This precedes the next Mac OUT timeout. |
| 17:15:24.488 | Mac 10,688-byte OUT fails after 2,731 ms. Kernel again reports zero bytes transferred. |
| 17:15:27.301 | Mac ends its session. |
| 17:15:28–43 | All three automatic reopen attempts fail to complete the RESET handshake. |
| 17:15:43.751 | Mac exhausts automatic retries; protection remains active. |
| 17:21:08.890 | Android opens a new accessory session. |

Both apps and the Mac privileged helper retained their processes: Mac PID 14453,
Android PID 9465, helper PID 12546 (launch count 1). At inspection the default route
was `utun5`, and Android had its foreground service and `DroidBridge:UsbRelay`
partial wake lock. These snapshots describe the inspection time, not proof of
every earlier scheduling state.

## What the evidence establishes

The reported disconnections are real AOA session losses. The first incident hit
the existing 2.5-second native write bound. In the second incident Android's frame
validation failed first, then Mac writes timed out because the Android bridge had
closed. `invalid AOA version` is a combined check of frame magic and version; it
does not by itself establish incompatible app versions or the exact byte-loss
mechanism. No offending payload was logged.

Source inspection explains why the second incident did not recover automatically:
`UsbAccessorySession.onClosed` clears the bridge and reports the error, but does
not reopen the accessory. Mac's bounded retries alone cannot recreate the closed
Android descriptor. Opening/connecting from the Android app can recreate it.

The initial cause of the frame validation error remains undetermined. There is
insufficient evidence to attribute it to cellular service, a cable defect, phone
app switching, or Android freezing. Increasing the OUT timeout again would not
address the confirmed missing Android reopen path.

## Live observation

A five-minute TLS-verified persistent HTTPS probe started at 17:22:04, using the
same connection for requests every ten seconds. It completed at 17:27:04 with
29 successful requests, zero errors, and zero reconnections; TCP local port 57606
was retained. Median request latency was 273 ms, maximum 1,247 ms (including the
initial TLS connection). At 17:24:40 and 17:25:59 USB OUT writes completed in
918 ms and 944 ms without session loss. A separate fresh HTTPS request returned
204, with DNS resolution 52 ms and total time 427 ms. The default route remained
`utun5`. A clean five-minute observation does not invalidate the earlier logged
failures or demonstrate that the intermittent issue is fixed.

## Follow-up work identified

- Trace frame corruption with bounded metadata diagnostics and a reproduction
  test, without logging tunneled contents or accepting malformed data.
- Reopen the Android accessory after unexpected bridge failure while service
  intent, USB presence, and permission remain valid. Explicit Stop/detach must
  cancel retries; a new session must wait for RESET and fresh DBP authentication.
- Exercise repeated fault/reconnect sequences alongside phone use. Existing TCP
  sessions still cannot survive destruction of their AOA transport.

No production code or installed binaries were changed during this inspection.
Evidence remains local in `build/evidence/2026-09-29-intermittent-1721/`.
