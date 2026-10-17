# Reliable USB transport implementation plan

> Execute inline using superpowers:executing-plans. Existing user authorization is to fix recurring download/Parsec disconnects, build, install and verify; preserve the running connection until an alternate route is verified. Do not commit the pre-existing dirty worktree or create new threads.

**Goal:** recover bounded raw USB omissions without corrupting, duplicating or retiring established AOA streams. Cumulative WINDOW v2 remains useful but cannot reconstruct missing DATA. Device evidence is under `build/evidence/2026-10-13-{stream-diagnosis,window-recovery-device}`.

**Architecture:** wrap the existing AOA v2 byte stream in a small reliable record channel, implemented in Swift and Kotlin with identical independent wire vectors. Keep existing per-stream authentication, service restrictions, byte credit, network binding and traffic policy. A new session handshake establishes a random 16-byte epoch; an epoch change is a physical-session boundary, never a promise to preserve sockets across unplugging.

**Wire contract:** fixed 80-byte header: magic `DBR3LINK` (8), kind (1:HELLO, 2:HELLO_ACK, 3:DATA, 4:ACK), reserved zero(3), payload length u32(4), epoch(16), sequence u64(8), cumulative ACK u64(8), first16 bytes SHA-256(body)(16), first16 bytes SHA-256(header first64)(16). Body at most16384. Controls have sequence0/body0. DATA sequence starts1; ACK is the last contiguous received DATA. Values are bounded to signed63-bit for interop. Each direction allows at most32 unacknowledged DATA records and512KiB. New DATA is backpressured when full; repeated ACKs never expand credit. Out-of-order/duplicate DATA causes the current ACK to be repeated but is delivered only once. A missing/invalid record is skipped by a bounded scanning decoder, never forwarded as AOA data. Retain at most one maximum record plus one read chunk while scanning.

**Recovery:** a dedicated writer polling at250ms resends unacknowledged records in order after500ms without ACK progress. Hello repeats on the same timer until acknowledged. No progress for10seconds fails the channel and uses existing network restoration/reconnect. Every blocking waiter wakes on Stop. Pending frames from an old epoch must never enter the new epoch. Handshake, ACK and retransmission writes are serialized with DATA. USB close must not run under a channel state lock. Diagnostics are counters/reasons only, no payload or credentials.

**Compatibility:** both apps must be updated together; no silent fallback to the known-unreliable byte stream. Existing AOA v2 framing stays inside the record layer. An unsupported peer is reported clearly. Helper DBP protocol remains unchanged.

## Task 1: codec and bounded decoder

- Add Swift `ReliableUsbRecord.swift` and Kotlin `ReliableUsbRecord.kt` with encode/decode and scanning parsers.
- First add failing tests for fixed independent wire bytes, split/coalesced records, missing512/1024/16384-byte segments, corrupted length/hash, embedded magic in payload and bounded garbage. Then implement and run the corresponding full USB/unit suites.

## Task 2: reliable state machine and IO ownership

- Add host `ReliableUsbTransport` around `AoaByteTransport`, and Android `ReliableAccessoryChannel` with InputStream/OutputStream views.
- Test real paired channels over controlled duplex pipes: dropped DATA and ACK, duplicates/reorder, exact multi-window byte delivery, bounded pending window, stale/future ACK, epoch fencing, retry exhaustion and cancellation. Test clocks may be injected; no production test-only APIs.
- Keep IO serialization separate from state locking; drain notifications before calling back into application queues.

## Task 3: integration and review

- Wrap only production USB paths. Retain raw-descriptor diagnostics below the new channel. Stop owns channel threads and descriptor together.
- Run full Swift USB/Shared/helper and Android unit/lint checks; run cross-language wire compatibility and loss injection. Obtain one fresh scoped review before device deployment.

## Task 4: signed deployment and acceptance

- Build a separate signed Mac app/APK, verify signatures and hashes. Verify Wi-Fi fallback, stop USB, update both apps retaining pairing; request phone reopen only if required.
- Repeat identical177MB IPv4/IPv6 downloads at2MiB/s with phone web/video use, Chrome download with full-file hash, and established connection observation. Record failures independently: near-EOF reset is not assumed to share the raw omission cause. Do not declare complete while these required checks fail.

## Progress and rulings

- Starting point: v2 cumulative WINDOW is deployed; unit196/USB checks pass. New device acceptance failed: IPv6 reset at176631531bytes; IPv4 reset at112879531bytes coincident with Android invalid-magic13:44:47KST and host session recovery13:44:57.
- Ruling: use the existing worktree and implement inline; all component interfaces are tightly coupled, and implementation delegation was not requested.
- Ruling: preserve prior evidence and unrelated dirty files; no commits or publication requested.
- Tasks 1–2 implemented; fixed a review finding by independently checking header integrity before trusting payload length. Added a separate Android watchdog for blocked raw writes. Full regression/review and device acceptance pending.

- Tasks 1–3 verified: Swift USB suite (including duplex1MiB corruption/loss/cancellation), shared298, helper18, Android206 unit tests + lint pass. Independent wire vector matches Swift/Kotlin. Fresh scoped review found header-length trust, blocked-write deadline, ACK starvation, liveness-budget ordering and initial-error propagation issues; all fixed and re-reviewed with no remaining critical/important findings.
- Task4: signed `DerivedData-ReliableUSB` created, APK updated successfully, old app stopped normally, Wi-Fi en0 HTTPS200 verified. New Mac app launched. Waiting for user to open updated phone app before Connect; helper replacement and device download acceptance pending.

- Reliable USB live acceptance identified a separate deterministic EOF bug: IPv6 176695531bytes and IPv4 176679531bytes, exit56, while USB stayed connected. `NWConnectionTransport.receive` discarded `isComplete=true` when final bytes were nonempty. The next NW receive raised POSIX96, incorrectly turning clean EOF into a reset and discarding the engine's queued tail. A production-source real-loopback reproducer and new permanent `NetworkEOFChecks.swift` failed before the fix and pass after EOF latching in both raw/exact paths. Full Shared304 and helper18 checks pass; scoped review confirms fix. Signed build: `DerivedData-ReliableUSBEOF`.
- EOF build deployment: old USB stopped normally, en0 HTTPS200 verified; new app launched. Helper replacement is waiting for the user to complete the standard macOS administrator authentication dialog. Android reliable APK unchanged; no phone reinstall/reopen required.
- Separate review follow-up (not attributed to these downloads): `TunnelController.engineCloseFlow` ignores DB_CLOSE_NORMAL on client FIN and fully cancels a relay intended to half-close. Core tests do not cover controller integration for this case. Keep separate from the confirmed final-data/EOF fix.

- Final signed EOF build/helper installed and hash verified; Android reliable APK retained. Live IPv6 and IPv4 each completed176897729bytes with exit0 in84.33s at2MiB/s. Native Chrome downloaded the same file completely to `~/Downloads/tor-browser-macos-15.0.24 (1).dmg`. All three SHA256 values equal169e30fe19d1cba2582cb29b75df9e76d908f0a5bb84f9e3bfe73c64046910d3. A60second HTTPS keepalive probe returned7/7 HTTP200 using one TCP connection/sourceport52946. No USB session failure appeared in the final download/keepalive observation logs. Evidence: `build/evidence/2026-10-13-reliable-usb-eof-device`.
- Download acceptance is now passed. Scope limits: final-build Parsec long-session testing and a fresh phone-concurrent-use confirmation are not completed; earlier phone-use confirmation14:22 preceded the final EOF build. Do not describe the final download checks as simultaneous phone-use or a guarantee against all disconnections. A separate controller client-FIN half-close issue remains documented above.
