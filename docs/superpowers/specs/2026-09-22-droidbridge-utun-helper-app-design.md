# DroidBridge utun Helper App — Design Spec

- **Date:** 2026-09-22
- **Status:** Approved design, pre-plan
- **Supersedes for the macOS data-plane host:** the NEPacketTunnelProvider hosting model in
  `2026-09-21-droidbridge-full-tunnel-design.md` (the NE extension target is kept dormant, see §12).

## 1. Overview

DroidBridge routes a Mac's traffic out through a paired Android phone's cellular link over
USB. The macOS side was built as a menu-bar app + `NEPacketTunnelProvider` app extension.
That extension needs the `com.apple.developer.networking.networkextension`
(`packet-tunnel-provider`) entitlement, which a **free Apple Personal Team cannot provision**.

This design replaces the *hosting* of the macOS data plane: instead of an NE extension, a
**root LaunchDaemon helper** opens a `utun` interface directly (root, no NE entitlement) and
runs the existing packet engine. A menu-bar app drives the helper over XPC. The data-plane
engine, relay stack, DNS bridge, pairing, and the entire Android app are reused unchanged.

## 2. Goals & Scope

**Goals**
- A double-clickable **menu-bar macOS app** that turns the Mac into a fail-closed full-tunnel
  exit through the Android phone's cellular link, signable with a **free Apple Development
  certificate** (no paid program, no SIP/AMFI changes).
- Reuse the existing engine/relay/pairing/Android app; change only the macOS packet
  source/sink and the privilege/kill-switch layer.
- Pass the B1 acceptance suite (14 criteria, 128-flow, 1-hour soak, performance) on the utun
  architecture and produce `v0.1.0-b1`.

**Scope (this design covers)**
- The `utun` packet path, the root helper, app↔helper XPC, privileged install, and the
  pf-based fail-closed kill-switch.

**Out of scope**
- The DBP wire protocol, pairing crypto, Android relay, and C data-plane engine — already
  built and device-verified; reused as-is.

## 3. Background & Constraints

- Signing works now: cert `Apple Development: <redacted-email> (<cert-id>)`, **Team
  ABCDE12345** (injected at build time, never committed). Fixed by installing the WWDR G3
  intermediate.
- The account is a **free Personal Team** → NE (Network Extensions) capability unavailable.
- Target: Apple Silicon, macOS 14+. Android app unchanged (device-verified: SM-F966N, LG U+
  LTE, `io.droidbridge.android`).
- Relay reaches the phone over `adb forward` on `127.0.0.1:27183` (loopback + USB).

## 4. Architecture

Two processes with a signed trust boundary:

```
user session                              root
┌───────────────────────────┐   XPC    ┌────────────────────────────────┐
│ DroidBridge.app (menu bar) │ ◄──────► │ DroidBridgeHelper (LaunchDaemon)│
│ · menu-bar GUI / popover   │ (verify) │ · UtunDevice (open/RW)          │
│ · pairing (existing)       │          │ · EngineBridge + C engine       │
│ · Keychain secret (existing)│         │ · RelayFlowConnection stack     │
│ · ADB client / adb forward │          │ · RelayDNSClient                │
│ · helper install/register  │          │ · RouteController               │
└───────────────────────────┘          │ · PfController (kill-switch)    │
        │ adb forward tcp:27183         │ · TunnelStateMachine            │
        ▼                               └────────────────────────────────┘
   [Android app] ◄──── USB ──────────────────────┘ 127.0.0.1:27183 (loopback)
```

- **App (user context):** GUI, pairing, Keychain, ADB — all correctly user-scoped; reuse
  existing `macos/HostApp`. Drives the helper (install / start / status / stop) over XPC.
- **Helper (root):** everything privileged — `utun`, default-route change, pf — plus the
  **data-plane engine** (it must own the utun fd). This is exactly what the NE extension did,
  relocated to a root daemon.
- **Trust boundary:** the helper is root, so it validates the **code-signing designated
  requirement of every XPC peer** (our app, Team ABCDE12345) and rejects anything else.
- **Secret handoff:** the app reads the 32-byte secret from the login Keychain and passes it
  to the helper on `startTunnel` over XPC; the helper holds it in memory only. This avoids a
  root daemon reading the user login Keychain.

## 5. Data Flow

**Outbound (Mac → internet):**
1. Helper creates `utun`, address `198.18.0.2/30`, sets the **default route to utun** (relay,
   loopback, and local subnets excepted).
2. Mac app packets → utun → helper reads fd (strips the 4-byte AF header) → `engine.ingest()`.
3. The C engine terminates TCP via lwIP, opens one `RelayFlowConnection` per flow →
   `127.0.0.1:27183` (loopback, tunnel-excepted) → `adb forward` → USB → Android → cellular.
4. DNS: virtual `198.18.0.1` → engine → `RelayDNSClient` → relay → cellular DNS.

**Inbound (responses):** relay → engine → `engineEmitPacket` → helper prepends the 4-byte AF
header → utun fd write → OS stack → app.

**Only new coupling point:** `TunnelController` currently depends on
`NEPacketTunnelFlow.readPackets/writePackets` (`TunnelController.swift:9,44,57`). Extract a
`PacketSource` protocol; the NE path keeps a thin `NEPacketFlowSource`, the helper adds a
`UtunPacketSource`. Engine/relay/DNS/state machine are reused unmodified.

### utun framing
macOS `utun` prepends a 4-byte address-family header (network-byte-order `AF_INET`) to every
read/write frame. `UtunDevice` strips it on read and prepends it on write. The payload (raw
IPv4 packet) is identical to what `NEPacketTunnelFlow` delivered via its separate `protocols`
array. B1 is IPv4-only; IPv6 frames are dropped (parity with the existing engine).

## 6. Privilege & Helper Lifecycle

- **Helper identity:** a root LaunchDaemon exposing an `NSXPCListener` Mach service; the app
  connects via `NSXPCConnection`. Both sides validate the peer's code signature.
- **Install/register (try SMAppService → fall back to manual):**
  1. On first run the app calls `SMAppService.daemon(plistName:).register()`.
  2. If unsupported/rejected (e.g., the free cert is refused), fall back: authenticate as
     admin (`AuthorizationServices` / `osascript … with administrator privileges`) and copy
     the launchd plist + helper binary into `/Library/LaunchDaemons` +
     `/Library/PrivilegedHelperTools`, then `launchctl bootstrap`.
  3. Either way the **helper binary and plist are identical**; only the registration code
     differs. The implementation spike (§9) decides which path the free cert supports.
- **XPC interface (minimal):** `installIfNeeded()`, `startTunnel(config, secret)`,
  `status()` / `metrics()` (polled), `stopTunnel()`.
- **Uninstall:** `unregister` (or `launchctl bootout` + file removal) → restore routes →
  remove pf anchor.
- **Crash resilience:** launchd `KeepAlive` restarts the helper; the pf ruleset persists in
  the kernel across a helper crash (see §7), so there is no leak window. Routes are restored
  only on clean stop, so an abnormal exit leaves the default route pointing at a dead utun —
  fail-closed by construction.

## 7. Kill-Switch / Fail-Closed (pf)

A pf anchor `com.apple/io.droidbridge` holds the ruleset (conceptually). The
`com.apple/` namespace is required because the stock macOS `/etc/pf.conf` evaluates
the `com.apple/*` wildcard anchor:
- `pass on lo0` — relay path is loopback `127.0.0.1:27183` (adb forward).
- `pass on utunN` — the healthy tunnel path.
- `block drop out on { en0, en1, … physical interfaces }` — every other egress denied.

Because the Mac→Android relay travels over **loopback + the USB kernel path** (not physical
IP egress), "block all out on physical interfaces" is a complete kill-switch, and it also
prevents DNS leaks (no port-53 egress on physical).

**Ordering is the fail-closed invariant:**
1. Start: **load pf → change default route to utun** (protect first, route second).
2. Stop: **restore route → unload pf** (route first, protect second).

There is never a window in which traffic can leave a physical interface unprotected.

**State is driven by the existing `TunnelStateMachine`** (CLT-tested):
- `ready→active`: pf permits the utun path.
- `relayLost→blocked`: pf keeps blocking (settings preserved), reconnect backoff 1/2/4 s.
- `persistentBlocked`: repeated failure keeps blocking and notifies the user.
- `stop`: close flows → restore route → unload pf.

"When to block" is the tested state machine; "how to block" is the new `PfController`.

## 8. Component Breakdown

**New (helper side, mostly small):**
- `macos/Helper/main.swift` — entry point: register XPC listener, lifecycle.
- `macos/Helper/UtunDevice.swift` — utun open + read/write loop + 4-byte AF header. The only
  low-level core.
- `macos/Helper/RouteController.swift` — default-route swap/restore (`route`), relay/local
  exceptions.
- `macos/Helper/PfController.swift` — load/flush the `com.apple/io.droidbridge` pf anchor.
- `macos/Helper/HelperService.swift` — XPC implementation + peer code-signature validation.
- `macos/Helper/{Info.plist, launchd.plist, Helper.entitlements}` — no NE entitlement.
- `macos/Shared/.../XPC/DroidBridgeHelperProtocol.swift` — shared XPC protocol.
- `macos/HostApp/Helper/HelperClient.swift` — app-side XPC client + install (SMAppService →
  manual fallback).

**Relocated for reuse (move into `macos/Shared`):**
- `EngineBridge.swift`, `CoreCallbacks.swift`, `NWDbpConnection.swift` (from
  `macos/PacketTunnel/Core`) — used by both the helper and the dormant NE extension.
- `TunnelController` — abstract the packet source/sink behind `PacketSource`, move the
  transport-agnostic controller into Shared; NE keeps `NEPacketFlowSource`, helper adds
  `UtunPacketSource`.
- `MetricsPublisher` — helper writes; app reads (via XPC/file rather than App Group).

**Reused unchanged:** C core / lwIP, `RelayFlowConnection`, `RelayDNSClient`,
`NWConnectionTransport`, `TunnelStateMachine`, `TunnelSettingsDescriptor`, pairing, Keychain
store, ADB client, the entire Android app, the HostApp GUI shell.

**Preserved (dormant):** `macos/PacketTunnel` (NE extension) stays in the tree and keeps
building unsigned, sharing the relocated engine, so the paid-account path can be revived (§12).

**project.yml:** add a `DroidBridgeHelper` target (links DroidBridgeShared + DroidBridgeCore),
embed the helper in the app bundle under `Contents/Library/…`, add
`SMPrivilegedExecutables` / SMAppService plist to the app. Team ID stays build-time-injected,
never committed.

## 9. Testing Strategy

- **Step 0 — spike (de-risk first):** a free-cert-signed app registers and launches a root
  helper via SMAppService; the helper opens a utun and pings itself. Output: SMAppService vs
  manual-install decision that fixes the registration code path.
- **Unit (CLT, no root — extend the `Checks` harness):**
  - `UtunDevice` AF-header framing (pure encode/decode).
  - `PfController` / `RouteController` — assert the **generated rule/command strings** (not
    executed).
  - XPC protocol contract + peer code-signature validation logic — with a fake peer.
  - `PacketSource` abstraction — `TunnelController` still passes the existing 108 checks via a
    fake source (regression guard).
- **Local integration (root, no Android — `sudo` dev script):** utun loopback (open utun,
  inject a packet, engine round-trips); pf actually loads/flushes and blocks a test
  connection.
- **Device acceptance (14 criteria — Android + cellular, reuse `scripts/b1-*` + `evidence.py`):**
  launch via app+helper (XPC) instead of NE; otherwise the existing evidence scripts. Extend
  `b1-preflight.sh` with a helper-install-state check.

## 10. Acceptance Criteria Mapping

The 14 B1 criteria map onto the existing `scripts/b1-*` evidence scripts (redacted via
`tools/evidence.py`), retargeted to app+helper launch: functional TCP/DNS/cellular-exit,
kill-switch (USB pull / relay kill → zero egress on `en0` by tcpdump), 128 concurrent flows,
1-hour soak, performance (≥20 Mbps, added RTT median ≤40 ms), and the security-boundary and
release-hygiene checks. No release tag until all pass.

## 11. Risks & Open Questions

- **SMAppService with a free cert** — the primary unknown; resolved by the Step-0 spike, with
  manual install as the guaranteed fallback. Helper code is identical either way.
- **pf ruleset correctness** — a wrong rule either leaks or bricks connectivity; validated by
  string-level unit tests plus the local root integration test before any device run.
- **utun MTU** — keep the engine's 1280 MTU; verify path MTU behavior over NAT64.
- **Route restoration failure** — if the helper dies mid-session, provide a recovery path
  (app-driven `stopTunnel`/uninstall re-asserts route restore + pf flush).

## 12. Rollout / Future

When a paid Apple Developer Program membership is available, revive the dormant
`macos/PacketTunnel` NE extension as an alternative front-end; it shares the relocated engine,
relay, and state machine, so the helper and the NE extension become two hosts of one core.
