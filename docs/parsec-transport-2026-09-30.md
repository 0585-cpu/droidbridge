# Parsec UDP and USB implementation, September 30, 2026

## Implemented

- Capability-gated authenticated UDP association (`0x44`, capability bit 10): one Android cellular UDP socket per Mac source address, family and port, retaining numeric destination metadata per datagram. Old peers continue using the legacy per-destination relay.
- The C engine keeps per-tuple packet synthesis. Swift groups the byte transport and routes replies to the original peer tuple. Tokens fence delayed close callbacks; Stop/network replacement clear groups and last-flow removal closes the association. Unsent packets for retired flows are discarded.
- Android retains destination filtering, TTL/hop policy, aggregate shaping, 64-packet queues, 256-peer limit and generation-bound socket ownership. Unknown or oversized inbound packets cannot establish/refresh permission. Valid traffic in either direction refreshes a permitted peer. Failed sends cannot roll back newer inbound activity.
- Fatal libusb read errors now terminate the framing session even if the API returns a positive transferred count. Valid partial timeout reads are retained. Android logs bounded last-good-frame metadata on parser failure without packet contents.

## Verification so far

Core tests, canonical vectors/Python foundation checks, 291 Shared Swift checks, USB codec/native/loopback checks, signed macOS Release build and strict app/helper code-signature validation passed. Android: 181 unit tests, zero failures/errors/skips; lint zero errors and 18 existing warnings; debug APK and instrumentation APK built. New Android platform tests exercise two destinations with the real unconnected socket for IPv4/IPv6, zero/max payloads and closure. The two new platform tests and five existing UDP platform tests ran on the connected SM-F966N: all seven passed.

Host full-controller association sharing, reply tuple/checksum, legacy fallback and delayed Stop/restart checks passed, alongside the existing 18 helper checks. Independent scoped review found no remaining blocking findings. Updated APK was installed without deleting data. The signed Mac app is running from DerivedData-ParsecTransport; installed helper SHA-256 matches the new embedded helper (efabfa5695a1860ace038ae38874575ab80272db7fad1894e57caa9ba94b4d9a). Pairing was retained. Wi-Fi fallback was verified with HTTPS 200 before the update, then the new USB utun5 route and HTTPS 200 were verified. The first manual helper command did not change its digest; the new app's built-in updater completed replacement.

## Remaining uncertainty

The original Android `invalid AOA magic` event recurred twice in the deployed build. The separate Mac USB-IN correction does not fix this demonstrated USB-OUT framing failure. Sustained device acceptance failed; implementation work remains open. The byte-loss/corruption mechanism is still under investigation, and the evidence does not establish phone interaction as its cause. The successful STUN comparison below covers only its tested endpoints and time.

## Artifacts and evidence

- `build/artifacts/DroidBridge-parsec-transport-debug.apk`
- `build/artifacts/DroidBridge-parsec-transport-mac.zip`
- App: `build/DerivedData-ParsecTransport/Build/Products/Release/DroidBridge.app`
- Detailed RED/GREEN logs and hashes: `build/evidence/2026-09-30-parsec-fix/`
- Prior observed STUN/Parsec failure: `docs/parsec-connectivity-2026-09-30.md`

## Device STUN comparison

One Mac UDP socket sent to three Parsec STUN IPv4 endpoints, then repeated the first. Before the fix (earlier diagnostic), mapped ports were 44055, 39587, 52510, 44055. On the normal hotspot they were 55389 for all four requests (RTT 225.62–239.83 ms). On the updated USB implementation they were 40610 for all four requests (RTT 219.31–248.18 ms). This proves the intended shared mapping for these tested destinations at this time; it is not a blanket guarantee about carrier NAT or every P2P peer. Raw JSON is in the evidence directory.

User reported three successful Parsec reconnects and began phone web/video use. The corrected 30-minute observer started at 16:34:04 KST. An initial 81-second observer preflight used a Python installation with no CA path and produced certificate-verification errors while native curl continued returning HTTP 200. That preflight was archived separately; observation now uses `/etc/ssl/cert.pem` with full certificate verification, without changing app code or disabling TLS validation. The accepted observation tracks one persistent HTTPS connection, default-route identity, Parsec UDP byte counters, Parsec disconnect/error events, Android USB logs and Mac USB transfer logs.

At the initial UI counter snapshot after update: UDP drops 425, UDP flows 5, total flows 33. This is the app-wide aggregate and does not identify Parsec losses. A reliable final counter delta was not captured.

## Failed sustained observation

The accepted observer ran from 16:34:04 to 16:49:41 KST (937 seconds, 94 samples), then was stopped after the failures. It did not complete the planned 30 minutes. The route was USB until the 16:48 transition to en0; current fallback HTTPS access remains available.

| Time (KST) | Observation |
| --- | --- |
| 16:36:24 | Existing HTTPS connection timed out. A new connection succeeded at 16:36:34. Parsec inbound UDP counters stopped increasing around this interval. |
| 16:37:20 | Parsec reported status -12007; this precedes the first recorded Android framing failure. |
| 16:38:43.972 | Android reader stopped after 109,140 frames / 19,378,441 encoded bytes; last validated frame DATA with 16,384 payload bytes. `invalid AOA magic` triggered accessory reopen. |
| 16:38:44 | Persistent HTTPS request timed out. Mac heartbeat failure at 16:38:50.978, automatic USB reconnect at 16:38:52.007. |
| 16:39:44 | Parsec reported another -12007 and later reconnected. |
| 16:43:48.215 | Second Android failure after 70,916 frames / 9,986,950 bytes; again last validated DATA payload 16,384. Accessory reopened. |
| 16:43:54 | HTTPS broken pipe and Mac heartbeat failure; automatic USB reconnect at 16:43:55.910. Parsec subsequently reported -12007 at 16:44:48. |
| 16:48:01.632 | Android logged ordinary USB disconnect; route transitioned to en0. This separate event has no recorded invalid-magic error. |

There were three HTTPS failures while the sampled route was USB and one during the later en0 transition. The observer's `parsec_disconnects: 1` counter matches only an explicit log phrase and **undercounts** status-code failures; use the event log above, not that counter, for acceptance. The first Parsec/HTTPS failure is not explained by the two later framing errors. No fatal or short USB-OUT write was recorded before either framing failure; occasional successful writes took roughly one second. A max-size preceding DATA frame is a lead, not proof of a specific boundary bug.

Sample timestamps precede the HTTPS request; UDP counters were collected after that request. The 16:36:24 timeout row therefore measures UDP around 16:36:32. Its inbound counter plateau cannot be dated more precisely from this observer. The next observer records separate completion/counter timestamps and counts -12007 status events directly.

Raw evidence is preserved in `observation-{android-usb,mac-usb,parsec}.log`, `observation-samples.jsonl`, and `observation-summary.json` under the evidence directory. Next investigation adds bounded transfer-length and parser-position records without packet contents and checks the independent earlier per-connection stall.

## Separately repaired lifecycle defect

Inspection found that `AndroidCellularTransport.onLinkPropertiesChanged` ignored its supplied properties and unconditionally retired the selected cellular generation. This closes all established sockets even for the initial metadata callback or DNS/proxy-only changes on the same `Network`. This is a demonstrated code-path defect, but retained field logs do not establish that this callback caused the 16:36 stall. The repair preserves sessions for initial/metadata-only callbacks while retaining retirement on real network loss/replacement or transport-relevant property changes. Endpoint-free retirement and association-exit diagnostics distinguish these paths in the subsequent device runs. The original USB framing defect remains open.

The comparison uses public interface, address/prefix, route and NAT64 properties. Hidden stacked-CLAT internals are not inspected through reflection and do not independently force every connection to close; network-bound sockets and their I/O failure cleanup remain authoritative. This limitation does not change numeric destination filtering or cellular-only binding.

Mac capabilities-query failure is another path that retires existing connections independently of USB framing failure. A new `NetworkRetirement` log records fixed reason labels and counts, with no endpoint or payload data. Its protocol-error label describes the surfaced error type: a timeout-triggered cancellation may surface as protocol EOF before the timer error wins, so that label alone is not evidence of wire corruption. The helper/controller checks and signed diagnostic Mac build passed; strict app/helper signature verification passed. New helper SHA-256: `8e6fd27bb196670de0ebd566b62ad6824dcb5bd95bd87a196fe249e1f7389c58`. The subsequent installation and observation are recorded below.

## Follow-up build and installation

The metadata-only retirement fix and bounded USB/network diagnostics passed 191 Android unit tests (29 USB tests included), with zero failures/errors/skips. Lint remains zero errors and 18 existing warnings. Four new callback regression cases failed against the old implementation and passed after the fix. Independent review accepted the public-API comparison and diagnostics, with the limits above.

The diagnostic APK was built and installed in place, retaining pairing. Its SHA-256 is `5290082c5db35540f469a079e2862acad89a6fca6bbcafda45ee42c6eea1fd1a`. Four phone instrumentation cases then passed: cellular TCP binding, selected-cellular DNS over UDP, and shared UDP sockets for IPv4/IPv6. The Mac diagnostic app is running from `build/DerivedData-ParsecDiagnostic/Build/Products/Release/DroidBridge.app`; its new helper was installed by the user and verified against the embedded SHA-256; launchd reports it running. Wi-Fi en0 remained the active route. The administrator helper-replacement command is complete. After the user reopened the phone app, the follow-up USB observation below reproduced the framing issue.

Follow-up evidence and the observer prepared for the next run are in `build/evidence/2026-09-30-parsec-diagnostic/`. Earlier failed observation files remain intact in the original evidence directory.

## Follow-up device observation: failed again

The installed diagnostic helper matched the expected hash and ran under launchd. Phone USB connected at 17:18:18; network generation initialized to 1 with zero sockets. The observer ran 17:19:34–17:31:38 KST (724 seconds, 73 samples). The user began concurrent Parsec/phone use at 17:23:41. Parsec's socket was confirmed on `utun5`, not merely inferred from the default route. No -12007 event was recorded during this run, but there were two HTTPS failures, Parsec WebSocket failures, and two USB framing failures; this is not a passing result.

| Time | Fresh diagnostic evidence |
| --- | --- |
| 17:25:46.119 | Invalid magic after 57,500 frames / 16,920,862 bytes; last DATA payload **140**. Raw read 57,799 returned 156 and ended exactly at completedBytes. The next raw read requested 16,384 and returned **5,648**, beginning at the rejected header position. |
| 17:25:49.872 | Host logged flow retirement reason `stop`, **after** the Android framing error. USB heartbeat expiry and reopen followed at 17:25:53–54. |
| 17:26:45.412 | Invalid magic after 6,087 frames / 1,005,006 bytes; last WINDOW payload **4**. Raw read 6,089 returned 20 and ended exactly at completedBytes; next raw read requested 16,384 and returned **700**, beginning at the rejected header position. |
| 17:26:48.802 | Host again retired flows with reason `stop` after the framing failure, then USB automatically reconnected. |

There was no logged cellular-generation retirement or capabilities-query-triggered retirement before these USB errors. Both errors begin at a fresh raw-read boundary after a small complete frame, so the earlier maximum-DATA-tail hypothesis does not explain all observed cases. A thread snapshot showed exactly one reader/writer/selector; no Tetrd or PdaNet process was found on either device. No duplicate-reader or parser-consumption defect was demonstrated by the renewed review.

Synthetic upload probes returned identical 256 KiB data. A Python 1 MiB upload failed with BrokenPipeError at 17:25:33, before the first frame error; its individual cause is unknown. A later curl 1 MiB upload and echoed response matched exactly over USB, and the same request matched over Wi-Fi, so a server body-size limit was not established. These probes use generated text, not user data.

The failed observer was stopped before the deliberate GUI disconnect. Mac then restored en0 and HTTPS 200; Wi-Fi upload comparison passed. The 30-minute acceptance remains incomplete. Further investigation must correlate the bytes offered by the host with the raw received chunks without treating phone interaction or a speculative kernel defect as established cause.

## USB chunk correlation diagnostic build

Added bounded SHA-256 fingerprints on host OUT chunks and Android raw reads, without retaining payload bytes or changing framing/recovery. Host retains 8,192 records and its first record; close saves one of at most four owned trace files. Packet-aligned suffix fingerprints test whether a short Android return is identical to the end of a longer host write. Android keeps eight raw reads and emits them only on existing failure. Equal-length matches prove byte identity; nonmatches are inconclusive because reads can split/coalesce or fall outside retained history. Counters are not aligned across accessory reopen/RESET epochs.

Aggregate verification passed: 193 Android unit tests, zero failures/errors/skips; APK and instrumentation APK builds; signed Mac Release and deep/strict signature verification. Scoped review found no blocker. Installed helper still matches `8e6fd27bb196670de0ebd566b62ad6824dcb5bd95bd87a196fe249e1f7389c58`; no administrator replacement was needed. APK was updated in place, user reopened the phone app, and USB utun5/HTTPS 200 were confirmed. Fresh observation began at 17:51:06 KST under `build/evidence/2026-09-30-parsec-diagnostic/digest-run/`; Parsec socket was confirmed on utun5. This is diagnostic deployment, not a confirmed repair.

Tracing changes scheduling. An optimized fake-transfer benchmark (512-byte endpoint, seven alternating rounds) added median 87.658 microseconds per encoded 16,400-byte frame and 0.539 microseconds per 156-byte frame, excluding native IO. Positive byte matches remain useful; a symptom disappearing under instrumentation alone is not acceptance of a fix. Build hashes and analysis script are in the diagnostic evidence directory.

During the digest run, three generated 1 MiB uploads via USB returned HTTP 200 and exact SHA-256-matching echoes (5.27, 6.01 and 6.08 seconds). This validates those probe payloads only. The user requested stopping after approximately 12 minutes. The last verified pre-stop sample was 18:03:06 KST: 73 HTTPS successes over the same local port, no USB framing error, and 80.8 MB of Parsec UDP received. The observer was not yet terminated when the user left; subsequent accessory unavailability and long wall-clock gaps continued into its raw summary. That summary’s `completed` flag must not be used as acceptance. `user-paused-result.json` records the valid cutoff; the planned uninterrupted 15 minutes was not completed.

## October 1 resumed test

User reconnected and requested continuation. At 09:33 KST, the same diagnostic Mac process and installed APK (last update September 30, 17:49) were confirmed. Helper digest still matches. Default route and Parsec UDP socket are on utun5; HTTPS returned 200. The prior observer has exited. The first device-written host trace was recovered: endpoint packet size 512, 98,808 calls, final 8,192 records retained, 25,704,424 reported bytes, and no short/error result within retained records. This trace covers the prior session, not a new framing failure.

Fresh evidence is in `build/evidence/2026-10-01-usb-digest/`. Observation started 09:34:29. The observer now bounds duration by wall time, stops on a sample gap over 45 seconds, and excludes clock/suspend gaps from completion. There is no new repair or installation in this resumed test.

## October 1 result and health-timeout repair awaiting deployment

The resumed observer completed 09:34:29–09:49:29 (900 wall seconds,90 samples). It recorded one established-HTTPS timeout and one Parsec-12007 disconnect. At09:37:42.187 the installed helper stopped90TCP flows and one association, with unchanged USB/utun5 and no preceding USB magic/heartbeat failure or Android cellular-generation retirement. The user confirms no button/cable action. Immediately before that stop, helper C3639 was cancelled after3.099s with0 bytes received/64 sent. Fresh HTTPS worked at09:37:59 while the prior Parsec UDP stream remained stalled; Parsec reported-12007 at09:38:42 and was reconnected at09:39:34.

Helper source and independent review strongly identify a health-probe deadline escalating to whole-controller stop/replacement. The reason its HELLO was unanswered is not proven. Android control dispatcher/keystore contention are candidates only. Separate capabilities-query retirement remains unchanged and was not the initiating label in this run. The original Android invalid-magic issue remains open.

The repair preserves an already-running controller only for typed health deadlines during the existing1/2/4-second retry budget; a fourth consecutive failure still stops it. Success resets the budget without replacing the controller. Explicit cellular-unavailable/authentication/protocol/other failures still block immediately; generation checks reject stale outcomes. New endpoint-free RelayHealth logs identify reason, attempt and retain/block action.

A prerequisite fix chooses the health task/deadline outcome before cancelling the connection, so cancellation-induced EOF cannot replace the initiating timeout. RED reproduced both the incorrect error type and unwanted packet-session retirement. GREEN:294 Shared checks and full helper suite, including preservation/recovery, budget reset/exhaustion, hard failures after grace, and stale success/failure metrics/session isolation. The existing wrong-secret echo fixture silently drops the request; an initially over-specific assertion against that fixture failed and was corrected by adding a signed-response corruption fixture for precise authentication classification. The failed-fixture log is retained separately.

The Release app/helper signatures pass. New helper SHA-256 is `dcc21657761ba008f055aca5cd390b3e0200bd7b4218f90c020f552a39dadfaa`; app is `build/DerivedData-HealthRetention/Build/Products/Release/DroidBridge.app`, archive `build/artifacts/DroidBridge-health-retention-mac.zip`. This build is not yet deployed. Mac Wi-Fi en0 was inactive, so the user was asked to connect an alternate network before helper replacement. Phone APK does not need another update.

The Mac observation log also contains local HelperChecks process diagnostics from building/running tests. These are not live helper/device retirements; distinguish their PIDs/process names from installed helper18085 and host20077. No observer remains running after09:49:29.

## Health-retention deployment

After the user prepared an alternate network, Wi-Fi en0 obtained10.227.27.108. The old app disconnected USB through its UI; fallback default route and HTTPS200 were verified. The new app was launched from DerivedData-HealthRetention and its normal Connect flow updated the helper. Installed helper now matches `dcc21657761ba008f055aca5cd390b3e0200bd7b4218f90c020f552a39dadfaa`; launchd reports running(PID23893). New hostPID23843 shows connected; USB utun5 and HTTPS200 from198.18.0.2 were verified. No Android APK update or pairing reset was needed.

A fresh 30-minute observer ran under `build/evidence/2026-10-01-health-retention-device/`, excluding local HelperChecks process messages and stopping on wall-clock gaps. The failure and actual duration are recorded below. Deliberate 10:34:46 flow closures belonged to the update transition and precede this observer.

## October 1: confirmed USB byte omission; acceptance failed

Observation ran from 10:36:59 to 10:45:40 KST (520 seconds, 52 samples), then was deliberately stopped after the failure. The summary's `user-stop` is the observer's generic SIGINT label; the investigator stopped it, not the user. The planned 30 minutes was not completed. There was one HTTPS failure, one Parsec -12007 disconnect and 36.3 MB of Parsec inbound UDP; every route sample remained on USB. The user began concurrent phone web/video use during the run.

At 10:42:20.013, Android rejected a new header after 68,892 completed frames. Adjacent whole-chunk SHA-256 matches now identify exactly which interval is absent between host OUT completion and Android raw `FileInputStream` return:

| Android raw read | Matching host write | Returned bytes |
| --- | --- | --- |
| 69214–69219 | 64755–64760, each unique and contiguous | 16384, 16, 16384, 16, 156, 97 |
| No intervening raw read | 64761, DATA frame 64507, offset 0 | Host reports all 16384 bytes written |
| 69220 | 64762, the same frame's tail at offset 16384 | 16 |

The cumulative host/Android offset difference increases by exactly 16,384 bytes across this boundary. The preceding 97-byte frame ends exactly at Android's completed-frame byte count, so the parser was aligned before it received the 16-byte tail as the next header. This establishes a complete chunk omission below the raw Java-read result, rather than parser consumption of the wrong amount. It does **not** identify the responsible kernel, USB controller, runtime, signal or cable, nor prove phone interaction caused it. Earlier failures lack these digest matches and are not retroactively assigned the same mechanism. Host write 64762 completes 202.742 ms after 64761; this is a monotonic-time delta, not proof of the cause.

Android reopened the accessory at 10:42:21.227. The deployed health fix retained the controller on the first deadline at 10:42:24.442 (`attempt=1 action=retain`), then correctly blocked on an actual transport error at 10:42:26.618. USB automatically reconnected at 10:42:27; Parsec reported -12007 at 10:43:20. Thus the health deadline grace was exercised, but it cannot repair the separate USB omission. No app GC/suspend/signal log was found immediately around the omission; absence of a log is not proof that none occurred.

Evidence includes `verified-missing-chunk.json` (seven independently rechecked unique matches), the complete bounded host trace, raw logs, `chunk-comparison.json`, and the failed observation summary. No production behavior was changed in response to this evidence. At the post-failure check en0 was inactive; the automatically recovered USB connection was left running to preserve the user's internet access. A further update requires restoring the fallback route first.

## October 1 afternoon: Parsec -6023 / -11010

The user reported repeated P2P connection failures. Parsec logged a successful connection at 14:48:46, an established-session -12007 at 14:56:09, then seven -6023 / -11010 failures from 14:56:24 through 14:59:44. The successful attempt had both IPv4 and IPv6 STUN replies; the failed attempts logged only IPv6 replies. This suggests a family-specific UDP-path problem, but does not alone prove the phone, carrier NAT, remote host or relay as its origin. The later USB event below cannot retroactively explain the earlier failure without further evidence.

At 15:00:31, during read-only diagnosis, Android again reported invalid AOA magic. The host trace and raw Android hashes show a **16-byte tail omission**, distinct from the earlier 16 KiB omission: Android raw reads 514698 and 514699 uniquely match host writes 314981 and 314983. The intervening write 314982 reports all 16 bytes written but is absent from the Android interval. The parser completes the preceding maximum DATA with the next frame's 16-byte header, then rejects the remaining bytes as a header. Evidence is `build/evidence/2026-10-01-parsec-6023/verified-tail-omission.json`; all adjacent matches and original traces are retained. No specific kernel mechanism is established.

USB automatically reconnected at 15:00:39. Both IPv4 and IPv6 HTTPS returned 204. At 15:02:42, a fresh IPv4 UDP socket received all four STUN responses across three Parsec servers, retaining the same external mapping, with RTTs 233–363 ms. This proves the new probe socket's current path only. The app UI shows connected. The user was asked to retry the same Parsec PC; no subsequent Parsec connection attempt was yet logged at the follow-up check. Wi-Fi en0 remains inactive; no deliberate USB stop, app restart, installation, router change or production-code change was performed.

There was also a `capabilities-timeout` retirement at 15:00:53, after the USB recovery, affecting 11 TCP flows and zero associations. This separate polling path is not covered by helper health-deadline retention and was not observed initiating the 14:56 failure. Keep it separate from the confirmed omission and pending Parsec recovery check.

The user subsequently confirmed reconnection. Parsec logs independently show both IPv4 and IPv6 STUN replies and `Client Status received: 0` at **15:13:49 KST**, followed by H.265 decoder setup. The default route remains USB utun5. No additional Android USB framing failure appears in the retained log from 15:02 through the 15:14:19 check. This confirms recovery of that connection attempt, not elimination of the underlying omission or sustained reliability. Evidence: `parsec-reconnect-success.log` and `reconnect-success.json` in the same directory.
