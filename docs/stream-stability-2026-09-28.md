# Streaming connection stability — 2026-09-28

## Report and evidence

The user reports that web browsing and video work through DroidBridge, but Codex shows reconnection/disconnection while generating responses. Local Codex logs contain repeated pubsub socket closes and reopens. These events corroborate instability but do not identify the failed model response transport or prove a single cause. The Mac's default route remained `utun4` throughout this investigation.

Two Android TCP bridge defects were reproduced locally before changing production code:

- The five-minute idle timeout applied separately to each direction. A continuing response could therefore outlive the quiet request direction's timeout. A regression test uses a shorter timeout and keeps the response active beyond it; the old implementation fails.
- Cancelling a bridge only interrupted blocking reads. Socket reads that need their descriptor closed could remain blocked, preventing flow cleanup. A close-only input fixture reproduces this failure without using the phone.

The full test suite also exposed an existing shutdown race: Kotlin `toList()` on a concurrent socket set observed a singleton size followed by an empty iterator. `RelayServer.cancelActiveFlows()` threw `NoSuchElementException` while a completed bridge removed its socket.

## Changes

- Both copy directions share an activity timestamp. Either direction transferring bytes refreshes the same idle deadline; the existing five-minute fully-idle limit remains.
- Cancellation, idle expiry, and half-close grace expiry close the owned endpoints to unblock socket IO. Production callers provide explicit socket close callbacks.
- Disconnect iterates the concurrent socket sets directly, avoiding the snapshot optimization race.

UDP behavior, pairing, routing, and the Mac application are unchanged by this patch.

## Verification and delivery

- Initial failing regression evidence: `build/evidence/2026-09-28-stream-stability/stream-red.log` and `stream-cancel-red.log`.
- Final Android JVM suite: 133 passed, zero failures/errors/skips. This includes streamed responses with a quiet upload direction, cancellation of interruption-resistant reads, existing TCP/UDP coverage, and 100 iterations of concurrent flow completion/disconnect.
- Android lint: zero errors, 17 warnings. Debug application and instrumentation APK builds succeeded.
- Direct instrumentation on the connected SM-F966N (Android 16) passed all three selected tests: streamed socket data followed by a late upload, TCP TTL/descriptor ownership, and IPv6 UDP Hop Limit/empty datagrams. The stream regression uses loopback sockets and a shortened idle interval; it is not a long-duration cellular/Codex test.
- The application signature verifies (APK v2); ZIP alignment passes the 16 KB check.
- Prepared application: `build/artifacts/DroidBridge-stream-stability-debug.apk`.
- Prepared test APK: `build/artifacts/DroidBridge-stream-stability-androidTest.apk`.
- SHA-256 hashes: `build/artifacts/STREAM-STABILITY-SHA256SUMS.txt`.

After the user confirmed an alternate connection was ready, the updated application and test APKs were installed with `adb install -r`. Both installations succeeded. The recorded first-install timestamp is unchanged; authenticated tunnel reconnection will provide the end-to-end check that the existing pairing still works. Device evidence is saved in `build/evidence/2026-09-28-stream-stability/device-stream-tests.log`.

The user reopened the phone app and the Mac displayed Connected. Before external connectivity could be verified, the Mac suffered a full network outage. Investigation found a separate Mac engine timer lifecycle defect; see `network-recovery-2026-09-28.md`. Actual Codex response stability remains unverified.

Installation must preserve pairing with `adb install -r`. Do not use Gradle connected-device test tasks on this paired phone: their cleanup previously uninstalled the app. Direct instrumentation still restarts the target app and interrupts the tunnel, so the user needs a suitable interruption window or alternate connection before installation/testing.
