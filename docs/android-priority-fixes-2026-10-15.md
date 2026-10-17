# Android priority fixes — 2026-10-15

This implements the ten improvements approved in chat, in connection-stability, phone-load, then pairing/UI order. It preserves DBAM/DBR3/DBP wire formats, cellular binding and destination policy, and TCP half-close.

## Changes

1. AOA socket reads pause at 256 queued output frames, leaving bounded capacity for control. Resume follows queue drainage; temporary congestion no longer overflows the 1,024-frame writer queue. DATA/FIN remain FIFO.
2. Accept, control read/write, and upstream connect execution are separated. Pending upstream connections are capped at 32. HEALTH remains responsive under 64 submitted slow connection attempts.
3. Cancellation closes and releases the pending cellular socket immediately and stops address fallback. The worker retains its admission permit until it exits, so a platform DNS resolver that ignores cancellation cannot create an unlimited backlog. Pending loopback client resets reclaim relay flow slots. AOA CLOSE is abortive; FIN remains a valid half-close. One receive window of early bytes is replayed without closing the live socket on EOF.
4. The reliable decoder reuses bounded scratch storage and caches a verified incomplete header instead of recopying all pending bytes on every fragment. Delivered payloads own their arrays. Integrity hashes and resynchronization are retained.
5. Descriptor trace counters remain active; full/prefix SHA fingerprints default off. Explicit diagnostic preference `diagnostics/usb_read_fingerprints=true` enables them for the next session. These optional diagnostics are separate from mandatory reliable-record integrity checks.
6. Both UDP paths buffer loopback input and read header fields in bulk. Association outbound queues retain parsed datagrams instead of encoding and immediately decoding them. Byte/count bounds, zero-length datagrams, direction validation and peer policy remain enforced.
7. USB resources take a bounded 10-second startup CPU lease. RESET establishes active ownership; host inactivity releases it without closing the descriptor. Existing bounded recovery leases remain separate. Another RESET reacquires active ownership.
8. Pairing accept/read/write cancellation closes owned sockets; a pairing deadline no longer leaves a blocking accept or partial-frame read alive.
9. ViewModel destruction and Forget cancel pairing. Cancellation and final persistence are serialized so a late commit cannot restore a forgotten peer. Facade state updates are fenced against obsolete coordinators.
10. Connected-but-unpaired and active-pairing UI states take priority over RUNNING readiness.

## Review repairs

A fresh scoped review found two integration regressions and one inherited race within the changed lifecycle path; all were repaired with failing-then-passing tests:

- Replay input must not use SequenceInputStream's implicit close-on-EOF behavior.
- Reliable ACK processing must not depend on the AOA/application consumer. A dedicated raw reader continues processing peer ACKs with a bounded receive queue (64 queued records; 512 KiB of unread payload, plus at most one already-consumed backing array and a decoded input chunk). When the queue cannot admit DATA, the receive sequence does not advance; the sender retains/retries that record. This preserves full-duplex progress without unbounded buffering or a wire-format change.
- Forget must serialize against persistence, not merely cancel a coroutine before clearing storage.

The targeted repair review found no remaining important issues. No unrelated inherited branch changes were reverted or committed.

## Validation

- Ordinary unit suite: **243 tests, 0 failures/errors/skips**.
- `lintDebug assembleDebug assembleDebugAndroidTest`: passed; **0 lint errors, 19 warnings**.
- Samsung SM_F966N, Android 16: **12 instrumented tests passed**. These use actual Android loopback sockets to cover pending cancellation, capped connection load/HEALTH, AOA congestion, reliable ACK progress with a paused application reader, TCP half-close and IPv4/IPv6 UDP.
- Incremental decoder test: 4 MiB in 512-byte fragments allocates **4,788,496 bytes** in the host JVM. Earlier audit measured about 157 MB for comparable fragmented input. This is cumulative allocation, not resident memory or measured phone power savings.
- Independent review and `git diff --check` completed. RED/GREEN logs, baseline source snapshot, scoped patch and final results are in `build/evidence/2026-10-15-priority-fixes/`.

## Deployment

The existing debug signer was verified before updating the phone with `adb install -r`; app data was not erased. The prior APK is retained as `device-before.apk`. The installed APK was independently hashed and matches the final build:

`03525fdbdd9a625f053321fa9be162adde3ea41f1d7e2c68f43f56554d14faba`

The Android test APK was installed and tests completed before reopening MainActivity. Wi-Fi `en0` routing and an HTTPS 200 response were confirmed before replacement. No Mac app/helper replacement was needed.

## Acceptance limits

The physical USB cable throughput, long screen-off/idle wake recovery, concurrent phone video use and Parsec soak were not established by the loopback instrumentation. Those remain device acceptance work; this patch does not establish that every thermal/vendor-freezer interruption is eliminated. The bounded pending-open abort monitor can add up to about 100 ms to connection setup while its outstanding socket read exits. No claim is made of measured battery savings.
