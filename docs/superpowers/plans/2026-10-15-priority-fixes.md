# Android priority fixes

Goal: implement the ten improvements approved in chat, preserving USB wire compatibility and TCP half-close.
Architecture: bounded queues/admission and cancellable socket ownership; keep transport integrity separate from optional diagnostics.
Tech: Kotlin coroutines, Java sockets/NIO, Android wake locks, Robolectric/JUnit.
Spec: user-approved priority list in the current conversation; reproduced findings in build/evidence/2026-10-15-{load-review,phone-load-review,apk-review}.
Global constraints: preserve existing uncommitted work, cellular binding/policy, pairing secrets, reliable retransmission and screen-off recovery. No automatic disruption of a USB-only internet route.
Review focus: cancellation ownership, bounded memory/threads, DATA/FIN ordering, half-close, lifecycle races.

## Task 1: connection stability
- Promote congestion/cancellation tests, prove RED. Add healthy control-under-load test.
- Pause socket ingress at USB high water, retain bounded control capacity.
- Isolate blocking upstream/control execution; cap pending opens.
- Close cancelled connects and reclaim reset clients; retain legitimate half-close/prefetched bytes.
- Expected: focused regressions and existing relay/USB tests pass.

## Task 2: phone load
- Add regression coverage for fragmented records, diagnostics opt-in, buffered/typed UDP, idle wake ownership.
- Reuse incremental decoder storage, cache valid incomplete headers, preserve integrity validation.
- Default to cheap trace counters; buffer UDP ingress and remove encode/decode queue roundtrip.
- Release active USB wake ownership when host session becomes idle; keep bounded startup/recovery leases.
- Expected: format/transport/UDP/resource tests pass and probes show reduced work.

## Task 3: pairing and UI
- Promote real deadline, destroyed-screen and unpaired-running regressions; prove RED.
- Make accept/read cancellation close owned descriptors; cancel pairing on screen teardown/forget.
- Present active pairing/unpaired state before ready state.
- Expected: pairing/UI regressions pass.

## Task 4: validation and delivery
- Full Android unit suite, lint, debug build/signature checks; fresh scoped review.
- Check device/route before any update. Keep source/build evidence and accurately report device verification limits.
