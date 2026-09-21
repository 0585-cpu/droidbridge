# DroidBridge B3 macOS Dual-Stack, LAN Policy, and Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS Packet Tunnel을 dual-stack으로 확장하고 ICMP relay, current-LAN bypass, ADB/event 기반 자동 재연결, sleep/wake 복구를 완성한다.

**Architecture:** Packet Tunnel은 항상 IPv4/IPv6 default route를 소유한다. HostApp은 ADB transport와 LAN 정책을 담당하고 Provider는 packet/data-plane과 fail-closed 상태를 담당한다. App Group runtime config와 provider messages는 versioned generation으로 동기화한다.

**Tech Stack:** Swift 6, NetworkExtension, Network.framework, SystemConfiguration/getifaddrs, SwiftUI, XCTest

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b3-dual-stack-resilience-design.md`

## Global Constraints

- IPv6 route `::/0`은 Android IPv6 unavailable 상태에서도 tunnel에 포함한다.
- loopback ADB transport는 IPv4 `127.0.0.1` excluded route만 사용한다.
- LAN bypass default는 denyAll이다.
- public/default route는 bypass할 수 없다.
- route update 실패 시 denyAll로 돌아간다.
- blocked/reconnecting 동안 tunnel settings를 제거하지 않는다.
- TCP flow는 handover에 resume하지 않는다.
- destination/payload/LAN peer를 로그하지 않는다.

## Review Focus

- IPv6 unavailable에서 AAAA/literal IPv6가 physical interface로 누출되지 않아야 한다.
- LAN route discovery가 utun, loopback, VPN, AWDL 인터페이스를 후보로 포함하지 않아야 한다.
- reconnect generation이 오래된 비동기 성공을 현재 상태에 적용하지 않아야 한다.
- HostApp crash/restart가 자신이 소유하지 않은 ADB forward를 제거하지 않아야 한다.
- sleep/wake 동안 route가 잠시 제거되는 window가 없어야 한다.

---

### Task 1: Dual-stack TunnelSettings descriptor and exact routes

**Files:**
- Modify: `macos/Shared/Sources/DroidBridgeShared/Tunnel/TunnelSettingsDescriptor.swift`
- Modify: `macos/PacketTunnel/Tunnel/TunnelSettings.swift`
- Modify: `macos/Shared/Tests/DroidBridgeSharedTests/TunnelSettingsTests.swift`
- Create: `macos/PacketTunnelTests/DualStackTunnelSettingsTests.swift`

**Interfaces:**
- Consumes: LAN bypass route set and relay IPv6 capability.
- Produces: `NEPacketTunnelNetworkSettings` with fixed IPv4/IPv6 addresses and routes.

- [ ] **Step 1: Write failing exact-route tests**

```swift
func testDualStackDefaultsAreAlwaysIncluded() throws {
    let descriptor = try TunnelSettingsDescriptor(lanPolicy: .denyAll)
    XCTAssertEqual(descriptor.ipv4Included, [.default()])
    XCTAssertEqual(descriptor.ipv6Included, [.default()])
    XCTAssertEqual(descriptor.ipv6Address, "fd7d:6272:6964::2")
    XCTAssertEqual(descriptor.ipv6PrefixLength, 126)
    XCTAssertEqual(descriptor.mtu, 1280)
}

func testIPv6UnavailableDoesNotRemoveIPv6DefaultRoute() throws {
    let descriptor = try TunnelSettingsDescriptor(relayIPv6Available: false, lanPolicy: .denyAll)
    XCTAssertTrue(descriptor.ipv6Included.contains(.default()))
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter TunnelSettingsTests
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/DualStackTunnelSettingsTests
```

Expected: FAIL because IPv6 settings are absent.

- [ ] **Step 3: Implement fixed dual-stack settings**

Create `NEIPv6Settings(addresses:["fd7d:6272:6964::2"], networkPrefixLengths:[126])`, set includedRoutes to `.default()`, DNS servers to both virtual gateway addresses, and MTU 1280. The relay IPv6 capability affects packet/DNS policy, not whether `::/0` is captured.

- [ ] **Step 4: Run tests**

```bash
swift test --package-path macos/Shared --filter TunnelSettingsTests
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/DualStackTunnelSettingsTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos
git commit -m "feat(macos): configure fail-closed dual-stack routes"
```

---

### Task 2: DBP capabilities and event channel client

**Files:**
- Modify: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayHealth.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayEventClient.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayCapabilities.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/RelayEventClientTests.swift`
- Modify: `macos/Shared/Tests/DroidBridgeSharedTests/RelayControlClientTests.swift`

**Interfaces:**
- Consumes: health v1/v2 and authenticated event stream.
- Produces: `AsyncThrowingStream<RelayNetworkEvent, Error>` and compatibility state.

- [ ] **Step 1: Write failing compatibility/event tests**

```swift
func testHealthV1DefaultsToIPv4TCPOnlyCapabilities() throws {
    let health = try RelayHealth.decode(b1HealthPayload())
    XCTAssertEqual(health.capabilities, [.tcp4])
    XCTAssertNil(health.networkGeneration)
}

func testEventReplayNonceIsRejected() async throws {
    let transport = ScriptedControlTransport(frames: [eventFrame(nonce: 7), eventFrame(nonce: 7)])
    let client = makeEventClient(transport)
    var iterator = client.events.makeAsyncIterator()
    _ = try await iterator.next()
    await XCTAssertThrowsErrorAsync { _ = try await iterator.next() }
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'RelayEventClientTests|RelayControlClientTests'
```

Expected: FAIL because health v2/event client do not exist.

- [ ] **Step 3: Implement versioned decode and event stream**

Parse v1 without reading beyond its fixed payload. Parse v2 exact lengths, capability reserved bits, NAT64 prefix, generation, and UTF-8 carrier. Event client verifies timestamp/HMAC/nonce per frame, emits latest event, reconnects only under an external coordinator, and sends no payload data.

- [ ] **Step 4: Run tests**

```bash
swift test --package-path macos/Shared --filter 'RelayEventClientTests|RelayControlClientTests'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Shared
git commit -m "feat(macos): consume relay capabilities and network events"
```

---

### Task 3: Dual-stack EngineBridge and ICMP relay client

**Files:**
- Modify: `macos/PacketTunnel/Core/EngineBridge.swift`
- Modify: `macos/PacketTunnel/Core/CoreCallbacks.swift`
- Create: `macos/PacketTunnel/Tunnel/RelayIcmpClient.swift`
- Create: `macos/PacketTunnelTests/EngineBridgeDualStackTests.swift`
- Create: `macos/PacketTunnelTests/RelayIcmpClientTests.swift`

**Interfaces:**
- Consumes: dual-stack C ABI, DBP ICMP messages, capability set.
- Produces: TCP6/UDP6 relay flows and ICMP replies/errors injected to C core.

- [ ] **Step 1: Write failing family and unsupported tests**

```swift
func testIPv6UDPFlowBuildsSixteenByteDestination() async {
    let relay = RecordingDatagramFactory()
    let bridge = makeBridge(relay: relay)
    bridge.testInvokeUDPOpen(flow: ipv6UDPFlow())
    XCTAssertEqual(await relay.lastDestination.addressBytes.count, 16)
    XCTAssertEqual(await relay.lastDestination.family, .ipv6)
}

func testUnsupportedICMPReturnsErrorToCoreWithoutRelayConnection() async {
    let relay = RecordingIcmpClient(capabilities: [])
    let core = RecordingCore()
    let bridge = makeBridge(core: core, icmp: relay)
    bridge.testInvokeICMPEcho(request: icmp6Request())
    XCTAssertEqual(core.icmpErrors, [.unsupported])
    XCTAssertEqual(relay.requestCount, 0)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/EngineBridgeDualStackTests -only-testing:DroidBridgePacketTunnelTests/RelayIcmpClientTests
```

Expected: FAIL because bridge/client are IPv4/TCP/UDP only.

- [ ] **Step 3: Implement family-aware relay calls**

Generalize destination model to enum IPv4/IPv6/domain. ICMP client sends one authenticated request per echo with 5-second timeout, caps payload 1200, and returns request ID unchanged. Engine callbacks copy 16-byte address/payload before scheduling async work.

- [ ] **Step 4: Run Packet Tunnel tests with TSan**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -enableThreadSanitizer YES
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos
git commit -m "feat(macos): bridge IPv6 and ICMP relay flows"
```

---

### Task 4: Safe current-LAN route discovery and policy model

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/LAN/LANRoute.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/LAN/LANRouteDiscoverer.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/LAN/LANAccessPolicy.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/LANRouteDiscovererTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/LANAccessPolicyTests.swift`

**Interfaces:**
- Consumes: injectable `getifaddrs` snapshot.
- Produces: validated directly-connected route candidates and excluded routes.

- [ ] **Step 1: Write failing exclusion-boundary tests**

```swift
func testIgnoresLoopbackUtunAWDLAndPublicRoutes() throws {
    let snapshot = InterfaceSnapshot.fixtures([
        .ipv4("en0", "192.168.50.12", "255.255.255.0", [.up, .running]),
        .ipv4("utun5", "10.0.0.2", "255.255.255.0", [.up]),
        .ipv6("awdl0", "fe80::1", 64, [.up]),
        .ipv4("en1", "203.0.113.5", "255.255.255.0", [.up]),
    ])
    XCTAssertEqual(try LANRouteDiscoverer(snapshot).routes(discovery: false),
                   [.ipv4(cidr: "192.168.50.0/24", interface: "en0")])
}

func testRejectsIPv4RouteBroaderThanSlash16() {
    XCTAssertThrowsError(try LANAccessPolicy.currentLAN(routes: [.ipv4(cidr: "10.0.0.0/8", interface: "en0")]))
}
```

Add Ethernet, ULA /64, link-local discovery toggle, duplicate route, point-to-point, down interface, default route, and IPv6 public prefix tests.

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'LANRouteDiscovererTests|LANAccessPolicyTests'
```

Expected: FAIL because LAN types do not exist.

- [ ] **Step 3: Implement pure discovery and validation**

Only interface names beginning `en` and marked UP/RUNNING are candidates. Exclude `lo`, `utun`, `awdl`, `llw`, bridge unless explicitly physical. Accept RFC1918 prefix length 16...30, ULA exactly /64, and optional link-local/mDNS exact routes. Sort and deduplicate before generating descriptor.

- [ ] **Step 4: Run tests**

```bash
swift test --package-path macos/Shared --filter 'LANRouteDiscovererTests|LANAccessPolicyTests'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Shared
git commit -m "feat(macos): discover safe current-LAN routes"
```

---

### Task 5: LAN bypass UI, confirmation, and atomic settings update

**Files:**
- Create: `macos/HostApp/UI/LANAccessView.swift`
- Modify: `macos/HostApp/UI/MenuBarContentView.swift`
- Modify: `macos/HostApp/App/DroidBridgeCoordinatorAdapter.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/TunnelRuntimeConfiguration.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/LANRuntimeConfigurationTests.swift`
- Create: `macos/PacketTunnelTests/LANSettingsUpdateTests.swift`

**Interfaces:**
- Consumes: route candidates and explicit user approval.
- Produces: versioned LAN policy in runtime config and provider settings update.

- [ ] **Step 1: Write failing approval and fail-safe tests**

```swift
func testPolicyCannotBecomeActiveWithoutMatchingApprovalDigest() throws {
    let routes = [LANRoute.ipv4(cidr: "192.168.1.0/24", interface: "en0")]
    XCTAssertThrowsError(try LANRuntimeConfiguration(mode: .currentLAN,
        routes: routes, approvalDigest: Data(repeating: 0, count: 32)))
}

func testSettingsFailureFallsBackToDenyAll() async throws {
    let applier = FailingThenSucceedingSettingsApplier()
    let controller = makeController(applier: applier)
    await controller.applyLANPolicy(.currentLAN(testRoutes))
    XCTAssertEqual(controller.activeLANPolicy, .denyAll)
    XCTAssertEqual(applier.lastApplied.excludedLANRoutes, [])
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter LANRuntimeConfigurationTests
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/LANSettingsUpdateTests
```

Expected: FAIL because LAN config/update flow is absent.

- [ ] **Step 3: Implement explicit route preview and approval digest**

UI lists exact CIDRs and warning text before enabling. Approval digest is SHA-256 over sorted canonical CIDRs plus discovery toggle and current tunnel ID. Provider applies new settings; on error immediately applies denyAll descriptor while routes remain captured. Default remains denyAll across fresh installs.

- [ ] **Step 4: Run Shared, Provider, and UI tests**

```bash
swift test --package-path macos/Shared --filter LANRuntimeConfigurationTests
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/LANSettingsUpdateTests
xcodebuild test -scheme DroidBridgeHostTests -destination 'platform=macOS'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos
git commit -m "feat(macos): add explicit current-LAN bypass"
```

---

### Task 6: Long-lived adb track-devices monitor and forward ownership

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/ADB/AdbTrackDevicesClient.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/ADB/ForwardOwnershipStore.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/AdbTrackDevicesClientTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/ForwardOwnershipStoreTests.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/ADB/AdbClient.swift`

**Interfaces:**
- Consumes: long-lived `adb track-devices -l` output and current serial.
- Produces: async device state stream and owned forward records.

- [ ] **Step 1: Write failing stream parser and ownership tests**

```swift
func testTrackDevicesParsesIncrementalSnapshots() async throws {
    let process = ScriptedProcess(chunks: ["R1\tdevice product:x\n\n", "R1\toffline\n\n", "\n"])
    let client = AdbTrackDevicesClient(process: process)
    let states = try await client.collectFirst(3)
    XCTAssertEqual(states.map { $0["R1"] }, [.device, .offline, nil])
}

func testCleanupRemovesOnlyMatchingOwnedForward() async throws {
    let store = ForwardOwnershipStore(ownerID: "host-a")
    store.record(serial: "R1", local: 27183, remote: 27183)
    let adb = RecordingAdbClient(existing: [ownedForward("host-a"), foreignForward("host-b")])
    try await store.cleanup(using: adb)
    XCTAssertEqual(adb.removed, [ownedForward("host-a")])
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'AdbTrackDevicesClientTests|ForwardOwnershipStoreTests'
```

Expected: FAIL because monitor/store do not exist.

- [ ] **Step 3: Implement resilient process stream**

Use a single child process, parse blank-line-delimited snapshots, cap line length 8 KiB, timeout no output at 60 seconds, and restart under coordinator control. Ownership records include owner UUID, serial, local/remote port, adb server serial, created timestamp; cleanup verifies exact forward still matches before removal.

- [ ] **Step 4: Run tests**

```bash
swift test --package-path macos/Shared --filter 'AdbTrackDevicesClientTests|ForwardOwnershipStoreTests'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Shared
git commit -m "feat(macos): monitor ADB devices and own forwards safely"
```

---

### Task 7: Generation-safe reconnect coordinator and Provider messaging

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Host/ReconnectCoordinator.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/Host/DroidBridgeCoordinatorCore.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/Tunnel/TunnelStateMachine.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/VPN/ProviderMessageClient.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/ReconnectCoordinatorTests.swift`
- Modify: `macos/Shared/Tests/DroidBridgeSharedTests/HostStateMachineTests.swift`

**Interfaces:**
- Consumes: device events, relay health/events, timer, provider messages.
- Produces: blocked/reconnecting/resumed state without route removal.

- [ ] **Step 1: Write failing stale-success and backoff tests**

```swift
func testStaleReconnectSuccessCannotResumeNewGeneration() async {
    let harness = ReconnectHarness()
    let first = await harness.startAttempt(generation: 1)
    await harness.transportLost(generation: 2)
    first.completeSuccess()
    XCTAssertNotEqual(await harness.state, .connected)
    XCTAssertEqual(await harness.currentGeneration, 2)
}

func testBackoffSequenceThenThirtySecondPolling() async {
    let clock = TestClock()
    let coordinator = makeCoordinator(clock: clock)
    await coordinator.failRepeatedly(count: 8)
    XCTAssertEqual(clock.requestedSleeps, [1,2,4,8,15,30,30,30].map(Duration.seconds))
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'ReconnectCoordinatorTests|HostStateMachineTests'
```

Expected: FAIL because reconnect coordinator/generations do not exist.

- [ ] **Step 3: Implement fail-closed reconnection**

On detach/offline: send provider `.blockTransport(generation)`, close flow managers, keep VPN active, then retry forward+health. Resume only after serial, peer ID, capability, and generation match current intent. User Disconnect cancels all attempts and then calls `stopVPNTunnel()`.

- [ ] **Step 4: Run tests with virtual clock**

```bash
swift test --package-path macos/Shared --filter 'ReconnectCoordinatorTests|HostStateMachineTests'
```

Expected: PASS without real sleeps.

- [ ] **Step 5: Commit**

```bash
git add macos/Shared
git commit -m "feat(macos): add generation-safe transport reconnect"
```

---

### Task 8: Sleep/wake, network-route change, and complete Host UI state

**Files:**
- Create: `macos/HostApp/System/SystemEventMonitor.swift`
- Modify: `macos/HostApp/App/DroidBridgeCoordinatorAdapter.swift`
- Modify: `macos/HostApp/UI/MenuBarContentView.swift`
- Modify: `macos/PacketTunnel/Tunnel/TunnelController.swift`
- Create: `macos/HostAppTests/SystemEventMonitorTests.swift`
- Create: `macos/PacketTunnelTests/WakeRecoveryTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: sleep/wake, interface-route change, relay events, reconnect state.
- Produces: blocked-on-wake verification and complete dual-stack status UI.

- [ ] **Step 1: Write failing wake barrier tests**

```swift
func testWakeBlocksPacketsUntilHealthAndForwardVerificationComplete() async {
    let harness = WakeHarness()
    await harness.systemDidWake()
    XCTAssertEqual(harness.providerState, .blockedTransport)
    XCTAssertEqual(harness.forwardedPackets, 0)
    await harness.completeForwardVerification()
    XCTAssertEqual(harness.providerState, .blockedRelayUnavailable)
    await harness.completeHealthVerification()
    XCTAssertEqual(harness.providerState, .connectedDualStack)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
xcodegen generate
xcodebuild test -scheme DroidBridgeHostTests -destination 'platform=macOS' -only-testing:DroidBridgeHostTests/SystemEventMonitorTests
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/WakeRecoveryTests
```

Expected: FAIL because wake barrier/system monitor do not exist.

- [ ] **Step 3: Implement wake barrier and UI states**

Subscribe to `NSWorkspace.willSleep/didWake` and network route changes. On wake, immediately instruct provider to block, restart ADB monitor if needed, verify owned forwards and relay health, refresh LAN candidates, then resume. Menu shows dual-stack/IPv4-only, ICMP capability, LAN bypass routes, reconnect attempt, and drop counters.

- [ ] **Step 4: Run all macOS tests**

```bash
swift test --package-path macos/Shared
xcodebuild test -scheme DroidBridgeHostTests -destination 'platform=macOS'
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos project.yml
git commit -m "feat(macos): recover safely across sleep and route changes"
```
