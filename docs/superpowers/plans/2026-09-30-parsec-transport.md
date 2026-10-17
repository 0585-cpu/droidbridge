# Parsec Transport Reliability Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement task-by-task. Independent USB and Android domains use dispatching-parallel-agents; parent integrates C/Swift.

**Goal:** Fix demonstrated AOA corruption defects and preserve UDP source sockets for Parsec P2P traffic.
**Architecture:** Capability-gated UDP association per source endpoint; one authenticated DBP stream per shared cellular socket. Strict existing AOA framing and bounded recovery remain.
**Tech Stack:** C engine, Swift host/helper, Kotlin Android, libusb/AOA.
**Spec:** `docs/superpowers/specs/2026-09-30-parsec-transport-design.md`

## Global Constraints

- Preserve unrelated dirty changes. No commit, push, dependency installation, pairing reset, network modification or device operations by subagents.
- UDP_ASSOCIATION bit 10; OPEN_UDP_ASSOCIATION 0x44; open 4 bytes; packet header 28 bytes; payload 0..1232.
- Existing authentication, policy, shaping and bounded Stop/recovery semantics are mandatory.
- Root owns device/UI/deployment. Serialize Gradle across agents. Each owns disjoint production paths.

## Review Focus

- Stop/open race: returned sockets close without publishing; pin with Android cancellation tests.
- Stale close after replacement: must not remove current source-port group; pin with host tests.
- Unknown inbound sender: dropped even after another peer was permitted; loopback third-peer test.
- Queued packets to retired flow: removed/ignored before send; host queue tests.
- Source reuse and old-peer fallback: no cross-session state; host capability/lifecycle tests.

### Task 1: USB integrity reproduction and fix

Files: macos/USB/**, Android usb package and USB tests only.
- [x] Read framing/USB lifetime; reproduce native fatal-read acceptance defect. Original Android invalid-magic trigger remains unreproduced.
- [x] Implement only evidence-backed fixes, add payload-free diagnostics if original trigger is unproven.
- [x] Run `make check-macos-usb` and relevant Android USB tests (coordinate Gradle).
- [x] Report demonstrated root cause separately from field-correlation hypotheses.

### Task 2: Android association protocol and relay

Files: Android protocol/network/relay and tests, excluding usb package.
Interfaces: `UdpAssociationOpen(family: Int, idleSeconds: Int)`; packet codec per spec; backend `openUdpAssociation(family: Int): DatagramSocket` returns bound-to-cellular unconnected socket. Server dispatches authenticated 0x44 into standalone association relay.
- [x] Write failing literal-codec and real two-peer shared-port tests plus rejection/cleanup cases.
- [x] Add message/capability, strict codecs, cellular socket lifecycle and relay implementation.
- [x] Expose capability only with live supported cellular family; retain legacy path.
- [x] Run Android unit/lint/build and document results.

### Task 3: C and Swift association integration

Files: core/include, core/src/packet_engine.c and protocol codec/tests; macos/Shared protocol/relay/Checks; macos/CoreHost callbacks/controller; helper checks as needed.
Interfaces: append `open_udp_endpoint(context, flow, family, dst, destinationPort, sourcePort, src)` callback. Add Swift peer-addressed frame/connection and source-endpoint grouping owner; legacy path when capability absent.
- [x] Pin source-port callback with C two-destination test; RED then minimal implementation.
- [x] Add same literal vectors, strict validation, bounded queue and fake/loopback transport lifecycle tests; RED/GREEN.
- [x] Group relay transport by family/source port; dispatch inbound to peer tuple; clear on session replacement.
- [x] Run core, Shared, helper and protocol fixture checks; additional full controller association integration checks passed.

### Task 4: Integration, review, signed build and device acceptance

- [x] Read scoped diff independently; address substantive findings.
- [x] Run affected full suites and signed Release/APK builds. Document prior warnings honestly.
- [x] Verify alternate route, update APK/Mac/helper, retain pairing and previous signed artifacts; seven phone UDP instrumentation tests passed.
- [x] STUN mapping comparison against hotspot and three user-reported Parsec reconnects.
- [ ] 30-minute observation with phone concurrent use: **failed** in the first 16-minute run; two Android invalid-magic recurrences plus an earlier independent existing-connection stall. See device report before claiming acceptance.
- [ ] Record tests not possible without user/remote-host participation; no blanket zero-disconnect claim.

### Task 5: Resolve field recurrences before acceptance

- [x] Preserve failed observer evidence and separate the earlier per-connection stall from later USB frame errors.
- [x] Check descriptor-read and USB transfer semantics; add bounded length/position diagnostics. Matching upstream does not prove exact Samsung kernel behavior.
- [ ] Establish and fix the original Android invalid-magic mechanism with a regression.
- [x] Fix independently reproduced metadata-only LinkProperties retirement; initial/equal/reordered/DNS/proxy/private-DNS callbacks preserve healthy sockets. 191 unit tests and four phone tests passed.
- [x] Capture an independent stall initiating boundary on October1: one helper health probe received0/sent64 bytes for3.099s, then helper stopped90TCP+1association; noUSB/network-generation retirement. Earlier September30 individual cause is not retroactively proven.
- [ ] Review, verify, deploy necessary changes and repeat sustained device acceptance.

### Task 6: Prevent a single control deadline from destroying healthy sessions

Evidence: October1 09:37:42 automatic all-flow stop follows the health HELLO deadline; USB/PF/routes persist, new HTTPS succeeds, old TCP and Parsec UDP break. User confirms no button/cable action.
- [x] Reproduce deadline cancellation surfacing protocol EOF; preserve initiating timeout before closing stalled child IO. Shared suite292 checks passed.
- [x] Regression: timeout/recovery retain same packet session; success resets budget; four misses block; hard auth/cellular/protocol failure immediately blocks, including after grace; stale generation outcomes cannot update metrics/retire current traffic. Existing Stop/old callback isolation checks also pass.
- [x] Allow only typed health deadline grace while already running, using existing1/2/4 retry budget; keep running status until actual block. Added fixed reason/attempt/action logs.
- [x] Review helper/Shared changes; 294 Shared checks and full helper suite; signed build and safe helper update. Installed helper digest verified. Device retest exercised first-deadline retention, then failed on the separate original USB byte omission; overall acceptance remains open.

October 1 10:42:20 evidence now positively correlates Android reads 69214–69219 to host writes 64755–64760, then Android read 69220 to host write 64762. The intervening successful host write 64761 (16384 bytes) is absent from that contiguous Android raw-read interval. Preserve the exact missing-chunk evidence and investigate the transport boundary; this does not establish a specific driver/signal mechanism or justify blind replay/resynchronization.

No speculative Android dispatcher/keystore changes: queued HELLO/auth work is a candidate reason for missing control reply, not proven in the field. Original invalid-magic USB issue stays open; capabilities polling has a separate failure-retirement path and was not the initiator in this run.
