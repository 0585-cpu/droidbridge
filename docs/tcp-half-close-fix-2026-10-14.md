# TCP half-close response retention and flow cleanup

## Confirmed defects

A Mac TCP FIN used to cancel the relay connection immediately. That discarded replies which arrived after the client finished sending and left the C connection waiting for relay EOF. Android also imposed an absolute ten-second grace after either EOF, truncating an otherwise active response.

The new regression cases additionally exposed two FIN-ordering hazards: lwIP TIME_WAIT or LAST_ACK could finish while upload bytes were still backpressured, and PCB completion could cancel bytes already accepted into the Swift FIFO. Remote-first EOF also needed upload activity to refresh its inactivity deadline.

## Changes

- Treat client FIN as a write-only shutdown. Seal and drain the outbound FIFO before issuing the transport FIN; keep receiving until remote EOF.
- Notify the packet engine of remote EOF separately from full relay completion. Both normal EOFs release the relay exactly once; errors and explicit stops still abort it.
- Detach finished lwIP PCBs without discarding pending upload bytes. Preserve that flow until its buffered tail and FIN reach the relay, or until its inactivity deadline expires.
- Bound either abandoned half-close to five minutes without data/ACK progress. Traffic in either surviving direction refreshes the deadline.
- On Android, remove the absolute ten-second EOF grace and use the shared inactivity deadline. Descriptor closure still unblocks cancellation and idle teardown; real I/O errors propagate and close both endpoints.
- No DBP/AOA wire format or pairing changes.

## Verification

Evidence: `build/evidence/2026-10-13-tcp-half-close/` (directory created before the date rollover).

- RED tests reproduced delayed-response loss, premature FIN, abandoned slot retention, both FIN-order tail losses, and the old Android ten-second truncation before the relevant fixes.
- Complete C suite passed. Independent review also compiled all current core sources with AddressSanitizer and UndefinedBehaviorSanitizer and passed the suite.
- Mac shared checks: 317 passed, including a real Network.framework/loopback half-close with a 300,000-byte response and remote-first upload continuation.
- Full helper checks passed, including real C/lwIP + controller tests with held relay writes, both FIN orders, exact upload/response bytes, and repeated single-slot reuse.
- Full USB checks and helper operation-lock check passed.
- Android: 217 unit tests, zero failures/errors/skips; lint and debug application/test APK builds passed.
- SM-F966N / Android 16: both StreamBridge instrumentation tests passed. Real Socket.shutdownOutput was tested in both directions with replies lasting beyond ten seconds. These tests used local loopback, not cellular traffic.
- Signed Release build and signatures passed. `/Applications/DroidBridge.app` and the APK were updated; pairing preference digest stayed identical. Previous Mac app retained in the evidence directory.

## Deployment status

The old USB tunnel was stopped normally and Wi-Fi HTTPS returned HTTP 200 from 172.30.1.16. The user completed privileged helper installation and reopened the phone app. The installed helper SHA-256 matches the signed corrected build, the installed APK matches the tested artifact, and the pairing digest is unchanged.

Initial USB connection attempts failed with a write timeout after Android exhausted its initial handshake retries while the Mac was unavailable. Switching the phone to charging mode using the supported no-argument USB command, then connecting from the Mac, restored accessory mode and the tunnel without re-pairing or restarting the phone process. This setup failure remains recorded separately from successful transfer validation.

### USB acceptance, 2026-10-14 (Asia/Seoul)

- 00:41:08–00:44:09: certificate-verified HTTPS returned 200 for 19/19 requests on the same source socket, 198.18.0.2:63012, over three minutes.
- 20 initial and 20 additional independent HTTP requests sent client FIN before reading the reply; all 40 returned the complete expected 68-byte body and matching digest.
- Tor Browser 15.0.25 downloaded completely: 176,943,035 bytes in 84.35 seconds, intentionally capped at 2 MiB/s. One curl connection, no retry/resume. SHA-256: `4771ad39f84323e60c1966b270a743c9a23f437569aca36dbb93988919c1a7ae`.
- IPv4 source was 198.18.0.2 through utun5. The Android process and default tunnel route remained unchanged across the three-minute test. No USB failure/retransmission or helper session retirement records appeared in the scoped log capture.
- Mac diagnostic UI showed 30 active flows before and after the additional 20-request batch. This demonstrates no observed increase for that batch, not an isolated claim that every background connection was closed.
- The C cleanup/inactivity suite and helper FIN-order/slot-reuse checks were rerun successfully. The five-minute inactivity boundary is covered with simulated time; it was not a five-minute live-idle acceptance run.
- The tunnel remains connected after verification. These results are bounded acceptance, not a long-duration stability guarantee.

## Limits

This fixes confirmed TCP end-of-stream and cleanup defects. It does not establish a cause for every historical USB transport error or prove that all Parsec/UDP disconnects are eliminated.
