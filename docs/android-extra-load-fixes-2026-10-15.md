# Additional Android load fixes — 2026-10-15

Additional bounded improvements following the priority fixes, requested to find other defects that add phone load. DBR3/DBAM/DBP formats, mandatory integrity checks, cellular policy and TCP half-close are unchanged.

## Changes

1. Reliable record encoding uses one output array and thread-local SHA-256 state instead of constructing providers and concatenating temporary arrays per record. Input ranges are handed directly to the decoder and reliable send window. The window still takes one owned copy after admission, so caller buffer reuse cannot corrupt retransmission.
2. The reliable writer waits for actual work or the next retry deadline instead of polling every 250 ms. A single scheduled watchdog replaces the permanent polling thread and is armed only when delivery or a raw write needs a deadline. ACK progress moves the effective deadline without waking or rescheduling a watchdog for every packet. The independent 10-second blocked-write/delivery failure detection remains.
3. The process-wide relay controller starts its periodic statistics/capability task only during a started run and cancels it on Stop. Generation checks prevent an old task from publishing into a replacement run. Stop publishes final totals and zero rates; late flow cleanup cannot reactivate rate sampling. Restart establishes a fresh sampling baseline.

## Reproduction and validation

- Host allocation probe: 4,096 records with 512-byte payloads (2 MiB payload; 2,424,832 wire bytes) allocated **10,163,384 bytes before** and **2,719,896 bytes in the final run**, about 73% less cumulative encoder allocation. This is not resident memory or a measured Android battery saving.
- Untouched accessory probe: worker wait entries over 1.1 seconds fell from **8 to 0**. The probe has no host handshake, packets or armed deadline; it does not claim zero wakeups for an active connection.
- The stopped controller previously continued publishing every second. The new regression fails before the lifecycle fix and passes afterward, covering stopped startup, Stop, restart, late cleanup and zero stopped throughput. Review exposed the otherwise stale nonzero rate after cancelling the ticker; that was also reproduced before repair.
- Final unit suite: **250 tests, no failures/errors/skips**. `lintDebug`, `assembleDebug`, `assembleDebugAndroidTest` passed; lint reports **0 errors and 19 warnings**.
- Samsung SM_F966N / Android 16: **17 instrumented tests passed** in 51.799 seconds. Coverage includes reliable loss/duplicates, paused-reader ACK progress, blocked-write deadline, late host, cancellation, stopped/restarted statistics, admission/control responsiveness, TCP half-close and IPv4/IPv6 UDP. The reliable channel tests simulate USB streams on Android; they are not a physical cable soak.
- Wire vectors, corrupted input/resynchronization, mutable input ownership, loss/duplicates, full-duplex ACK progress, late first host, blocked write deadline and stop cancellation remain covered.
- The Robolectric USB fixture used a regular file as its simulated pipe and raced against immediate EOF. Its test now explicitly awaits recovery before testing repeated connect/detach after permission loss. A deterministic active-session reuse test and existing wake-lock lifecycle tests preserve the original coverage without pretending the file is a blocking USB device.
- Fresh scoped code review completed; the stopped-rate issue and active-session test coverage feedback were addressed. `git diff --check` passed.

## Deployment and evidence

Mac Wi-Fi routing and an interface-bound HTTPS 200 response were confirmed before update. The existing debug certificate matched, and the APK was updated with `adb install -r`; app data was not erased. The previous APK is backed up. No Mac app or helper change was required.

Build SHA-256: `1d75fa77bd1bf4df0c86b83ca933deb3734365938d980defb313ae6a8b14ed0a`.

Evidence, baseline source snapshot, scoped patch and RED/GREEN logs: `build/evidence/2026-10-15-extra-load-fixes/`.

## Remaining profiling and acceptance work

The unlimited-rate direction mutex, UDP per-flow idle timers/peer-list scans and aggregate socket-thread limits remain profiling candidates. Their practical cost has not been established, so no speculative limits or architecture rewrite were applied.

The automated checks do not establish physical USB throughput, a long Parsec session, screen-off recovery during concurrent phone video use, or an Android power/temperature improvement. These require separate comparable device measurements.
