# Android relay load reduction — 2026-10-15

The two morning interruptions correlated with Samsung SSRM SLOWDOWN and the app entering the vendor `/abnormal` freezer cgroup. This patch removes avoidable work; it does not disable thermal protection. Earlier diagnosis is preserved in `build/evidence/2026-10-15-interruption-repeat/incident.json`.

## Production changes

- `RelayViewModel` no longer decrypts the pairing record on each traffic/state update. It loads the display name initially and on persisted pairing changes, then wipes the temporary secret copy. Authentication remains unchanged.
- `PairingSecretStore.changes` emits on subscription and persisted changes. Android preference observers cover writes through another store instance and unregister with the ViewModel. This also preserves freshness when an older pairing facade completes after screen recreation.
- `RelayMetrics` packet paths update atomic counters only. The existing one-second controller tick publishes UI totals; lifecycle and policy errors still publish immediately. HEALTH and UDP control responses read live counters.
- `AoaAccessoryBridge` stops polling the incoming queue once empty, retaining the 1,024-frame fairness limit. A selector-owned 16 KiB read buffer is reused; outgoing DATA owns a copied payload, and receive-window limits remain enforced.

## Regression evidence

Evidence directory: `build/evidence/2026-10-15-load-reduction/`.

- RED tests reproduced per-update key operations, per-packet UI publication, screen-recreation/cross-instance metadata staleness, and excessive selector allocation before the relevant fixes.
- 1,000 traffic/state updates cause no additional key operations. 10,000 transfer/drop updates preserve exact live totals without waking UI collectors per packet.
- Host-JVM allocation measurement for 256 small replies (8 KiB payload): 4,337,272 bytes before, 123,384 bytes after. This measures selector allocations, not Android CPU or battery improvement.
- Two existing intermittent fixture failures were investigated rather than suppressed. The reliable duplex fixture stopped its phone reader before the opposite direction finished, leaving ACKs undrained; captured thread stacks confirmed the missing reader and blocked writer. It now drains control traffic until host completion, retaining exact 1 MiB payload and cumulative-ACK assertions. It passed ten consecutive repetitions.
- The UDP server fixture published an unbound socket to concurrent workers, unlike the production cellular controller. It timed out on repetition 44. Binding its loopback socket before publication preserved the existing zero/max/oversized-datagram assertions and passed all 50 repetitions. No production UDP logic was changed for this fixture correction.
- Final ordinary Android suite: **226 tests, zero failures/errors/skips**. `testDebugUnitTest lintDebug assembleDebug` passed after both fixture corrections. The installed production APK still matches the final build hash.
- Independent read-only review covered production changes, metadata observation and both fixture corrections, with no outstanding actionable findings in this delta. Validation commands and all failed/passing runs are retained in the evidence directory.

## Deployment and bounded physical validation

The debug APK was verified with the existing signer and installed as an update after default Wi-Fi routing and HTTPS 200 were confirmed. Installed APK SHA-256 matches `fe318f3611f893b7ac22d5e21fe3e7ef1b78f4a649ba20ab1aabc474f06b50a7`; pairing preference digest is unchanged. The prior APK is saved for rollback. No Mac app/helper replacement was required.

On 2026-10-15, 11:29:35–11:30:41 KST, Android PID 8692 and USB interface `utun4` were retained:

- 33/33 HTTPS responses over the same TCP socket, no errors; maximum observed response time 1.729 seconds.
- A 16 MiB range of the previously verified Tor Browser test download completed without retry/resume and matched the known file prefix SHA-256 `905700167f179f50f2837a92488d7fa5593304f4d0919d03eba335068896b7fe`.
- 69 target-app keystore operations in about 66 seconds. Earlier diagnosis observed 4,263/minute; workloads differ, so this is supporting evidence rather than a controlled CPU comparison.
- Seven process-cgroup snapshots contained no `/abnormal` membership. The app had just been restarted and opened, so this does not establish long-duration thermal stability.
- Captured logs contain no health-probe timeout, USB retransmission, transport-stop or frame-reader failure during this interval.

## Remaining limits

Long-duration screen-off operation, concurrent phone video use and Parsec stability still require physical acceptance. The independently reproduced shared default-IO starvation under many pending connects is not fixed by this load-reduction patch. No claim is made that all interruption causes have been eliminated.
