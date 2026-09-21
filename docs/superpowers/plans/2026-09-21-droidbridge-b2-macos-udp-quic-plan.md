# DroidBridge B2 macOS UDP and QUIC Data Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B1 Packet Tunnel에 IPv4 UDP flow extraction, DBP datagram relay, bounded backpressure, QUIC-compatible packet reinjection을 추가한다.

**Architecture:** C core가 UDP flow lifecycle과 packet synthesis를 담당하고 Swift `UDPSessionManager`가 flow별 `RelayDatagramConnection`을 소유한다. DNS virtual address는 기존 DNS bridge로 유지하며, 일반 UDP는 flow별 persistent relay connection을 사용한다.

**Tech Stack:** Swift 6, NetworkExtension, Network.framework, XCTest, C17 bridge

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b2-udp-quic-design.md`

## Global Constraints

- Packet Tunnel MTU는 1,280이다.
- UDP payload는 1,232 bytes를 넘지 않는다.
- virtual DNS destination은 일반 UDP manager에 전달하지 않는다.
- flow별 relay connection 하나를 사용한다.
- direction별 queue는 64 datagrams/256 KiB, drop-oldest다.
- blocked 상태에서 settings를 제거하지 않는다.
- UDP relay failure가 TCP engine을 종료하지 않는다.
- destination과 payload를 OSLog에 기록하지 않는다.

## Review Focus

- relay OPEN 전 들어온 datagram이 bounded queue에 정확히 보존돼야 한다.
- flow close callback과 remote EOF가 동시에 발생해도 connection close가 한 번이어야 한다.
- Packet Tunnel stop 후 C callback이 해제된 Swift object를 호출하지 않아야 한다.
- DNS packet이 일반 UDP relay로 중복 전달되지 않아야 한다.
- QUIC datagram ordering은 보존하되 queue overflow에서 오래된 datagram만 drop해야 한다.

---

### Task 1: Swift DBP UDP types and canonical codec parity

**Files:**
- Modify: `macos/Shared/Sources/DroidBridgeShared/Protocol/DbpCodec.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Protocol/DatagramFrameCodec.swift`
- Modify: `macos/Shared/Tests/DroidBridgeSharedTests/DbpCodecTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/DatagramFrameCodecTests.swift`

**Interfaces:**
- Consumes: canonical B2 fixtures.
- Produces: `OpenUDP`, `OpenUDPOK`, `DatagramFrame`, async frame encoder/decoder.

- [ ] **Step 1: Write failing vector and segmented-read tests**

```swift
func testCanonicalOpenUDPVector() throws {
    let payload = Data(hex: "0101bb045db8d8220078")
    XCTAssertEqual(try DBPCodec.decodeOpenUDP(payload),
                   OpenUDP(address: .ipv4([93,184,216,34]), port: 443, idleSeconds: 120))
}

func testFrameDecoderHandlesEveryHeaderSplit() async throws {
    let encoded = DatagramFrameCodec.encode(.init(flags: 0, sequence: 7, payload: Data("abc".utf8)))
    for split in 0...encoded.count {
        let source = SegmentedByteSource([encoded.prefix(split), encoded.dropFirst(split)])
        XCTAssertEqual(try await DatagramFrameCodec.read(from: source).payload, Data("abc".utf8))
    }
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'DbpCodecTests|DatagramFrameCodecTests'
```

Expected: compile failure because UDP types/codecs do not exist.

- [ ] **Step 3: Implement strict codecs**

```swift
public struct DatagramFrame: Equatable, Sendable {
    public let flags: UInt8
    public let sequence: UInt32
    public let payload: Data
}

public enum DatagramFrameCodec {
    public static let maximumPayload = 1232
    public static func encode(_ frame: DatagramFrame) throws -> Data
    public static func read<S: AsyncByteSource>(from source: S) async throws -> DatagramFrame
}
```

Validate reserved byte, flags mask, maximum before allocating payload, and exact EOF. Use network byte order helpers shared with B1 codec.

- [ ] **Step 4: Run tests**

```bash
swift test --package-path macos/Shared --filter 'DbpCodecTests|DatagramFrameCodecTests'
```

Expected: PASS for B1 and B2 fixtures.

- [ ] **Step 5: Commit**

```bash
git add macos/Shared
git commit -m "feat(macos): add DBP UDP framing"
```

---

### Task 2: RelayDatagramConnection state machine

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayDatagramConnection.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/DatagramQueue.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/RelayDatagramConnectionTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/DatagramQueueTests.swift`

**Interfaces:**
- Consumes: `NWConnectionProtocol`, pairing secret/session authenticator.
- Produces: `open()`, `send(_:)`, `datagrams: AsyncThrowingStream<Data, Error>`, `close(reason:)`.

- [ ] **Step 1: Write failing state and queue tests**

```swift
func testDatagramsBeforeOpenAreFlushedInOrder() async throws {
    let nw = ScriptedNWConnection()
    let connection = makeDatagramConnection(nw: nw)
    try await connection.send(Data("one".utf8))
    try await connection.send(Data("two".utf8))
    nw.deliver(openUDPOK(flowID: 7, maxPayload: 1232))
    try await connection.open()
    XCTAssertEqual(nw.sentDatagramPayloads, [Data("one".utf8), Data("two".utf8)])
}

func testQueueDropsOldestAndCountsDrop() throws {
    var queue = DatagramQueue(maxDatagrams: 2, maxBytes: 100)
    queue.push(Data([1])); queue.push(Data([2])); queue.push(Data([3]))
    XCTAssertEqual(queue.pop(), Data([2]))
    XCTAssertEqual(queue.dropCount, 1)
}
```

Add authentication failure, oversized payload, remote EOF, sequence gap, and close-once tests.

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'RelayDatagramConnectionTests|DatagramQueueTests'
```

Expected: compile failure because types do not exist.

- [ ] **Step 3: Implement actor-isolated lifecycle**

```swift
public actor RelayDatagramConnection {
    public enum State { case idle, authenticating, opening, open, closing, closed }
    public func open() async throws
    public func send(_ datagram: Data) async throws
    public nonisolated var datagrams: AsyncThrowingStream<Data, Error> { get }
    public func close(reason: UDPFlowCloseReason) async
}
```

Use one writer task to serialize frames. `close` stores the first reason, cancels tasks, finishes stream exactly once, and releases `NWConnection`.

- [ ] **Step 4: Run tests**

```bash
swift test --package-path macos/Shared --filter 'RelayDatagramConnectionTests|DatagramQueueTests'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Shared
git commit -m "feat(macos): add UDP relay connection"
```

---

### Task 3: UDPSessionManager and flow lifecycle

**Files:**
- Create: `macos/PacketTunnel/Tunnel/UDPSessionManager.swift`
- Create: `macos/PacketTunnel/Tunnel/UDPFlowModels.swift`
- Create: `macos/PacketTunnelTests/UDPSessionManagerTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: core flow callbacks and `RelayDatagramConnectionFactory`.
- Produces: `open(flow:)`, `send(flowID:payload:)`, `close(flowID:reason:)`, inbound callback to C core.

- [ ] **Step 1: Write failing manager race tests**

```swift
func testOpenAndCoreCloseRaceLeavesNoSession() async {
    let factory = BlockingDatagramFactory()
    let manager = makeManager(factory: factory)
    async let opening = manager.open(flow: testFlow(id: 9))
    await factory.waitUntilCreating()
    await manager.close(flowID: 9, reason: .coreClosed)
    factory.finishCreation()
    _ = await opening
    XCTAssertEqual(await manager.activeCount, 0)
    XCTAssertEqual(factory.createdConnections.first?.closeCount, 1)
}

func testInboundDatagramIsCopiedBeforeCallbackReturns() async throws {
    let recorder = CoreDeliveryRecorder()
    let manager = makeManager(core: recorder)
    try await manager.injectRemote(flowID: 1, bytes: Data([1,2,3]))
    XCTAssertEqual(recorder.delivered, [Data([1,2,3])])
}
```

- [ ] **Step 2: Run and verify failure**

```bash
xcodegen generate
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/UDPSessionManagerTests
```

Expected: compile failure because manager target/types do not exist.

- [ ] **Step 3: Implement actor-backed session map**

Use `[UInt64: SessionEntry]` inside an actor. Store generation token per entry; asynchronous open completion checks the generation before installing. Inbound datagram calls `db_engine_udp_deliver` on the single engine queue. Manager enforces 256 UDP and 512 combined hard limits before creating a connection.

- [ ] **Step 4: Run tests**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/UDPSessionManagerTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos project.yml
git commit -m "feat(macos): manage UDP relay sessions"
```

---

### Task 4: C callback bridge and buffer ownership

**Files:**
- Modify: `macos/PacketTunnel/Core/CoreCallbacks.swift`
- Modify: `macos/PacketTunnel/Core/EngineBridge.swift`
- Create: `macos/PacketTunnelTests/EngineBridgeUDPTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: B2 C callback ABI.
- Produces: safe Swift copies and serialized calls back to `db_engine_udp_*`.

- [ ] **Step 1: Write failing ownership test**

```swift
func testUDPCallbackCopiesEphemeralCBuffer() async throws {
    let manager = RecordingUDPManager()
    let bridge = EngineBridge(udpManager: manager)
    var bytes: [UInt8] = [1,2,3,4]
    bridge.testInvokeUDPDatagram(flowID: 4, pointer: &bytes, length: bytes.count)
    bytes = [9,9,9,9]
    XCTAssertEqual(await manager.sentPayloads, [Data([1,2,3,4])])
}

func testCallbackAfterShutdownIsIgnored() async {
    let bridge = EngineBridge(udpManager: RecordingUDPManager())
    bridge.shutdown()
    bridge.testInvokeUDPOpen(flowID: 1, key: testKey())
    XCTAssertEqual(await bridge.testActiveUDPCount, 0)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/EngineBridgeUDPTests
```

Expected: FAIL because UDP callbacks are unbound.

- [ ] **Step 3: Implement callbacks with explicit lifetime**

Each C callback uses `Unmanaged<EngineBridge>.fromOpaque(context).takeUnretainedValue()`, checks an atomic `isShuttingDown`, immediately copies payload to `Data(bytes:count:)`, then schedules work on the engine/session actor. Shutdown first disables callbacks in C, drains the serial engine queue, then releases manager references.

- [ ] **Step 4: Run tests and Thread Sanitizer build**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -enableThreadSanitizer YES -only-testing:DroidBridgePacketTunnelTests/EngineBridgeUDPTests
```

Expected: PASS without race reports.

- [ ] **Step 5: Commit**

```bash
git add macos
git commit -m "feat(macos): bridge UDP packet core callbacks"
```

---

### Task 5: PacketTunnelProvider UDP integration and DNS exclusion

**Files:**
- Modify: `macos/PacketTunnel/PacketTunnelProvider.swift`
- Modify: `macos/PacketTunnel/Tunnel/TunnelController.swift`
- Modify: `macos/PacketTunnel/Tunnel/TunnelSettings.swift`
- Modify: `macos/PacketTunnel/Metrics/MetricsPublisher.swift`
- Create: `macos/PacketTunnelTests/PacketTunnelUDPIntegrationTests.swift`

**Interfaces:**
- Consumes: packetFlow IPv4 packets, EngineBridge, UDP manager.
- Produces: full IPv4 TCP+UDP tunnel with B1 DNS bridge.

- [ ] **Step 1: Write failing routing and fail-closed tests**

```swift
func testVirtualDNSPacketUsesDNSBridgeNotUDPManager() async throws {
    let harness = PacketTunnelHarness()
    await harness.inject(ipv4UDP(destination: "198.18.0.1", port: 53, payload: dnsQuery()))
    XCTAssertEqual(harness.dnsBridge.queryCount, 1)
    XCTAssertEqual(await harness.udpManager.openCount, 0)
}

func testUDPRelayFailureDoesNotRemoveTunnelSettings() async throws {
    let harness = PacketTunnelHarness()
    await harness.start()
    await harness.udpManager.failAll(.relayUnavailable)
    XCTAssertEqual(harness.settingsApplyCount, 1)
    XCTAssertEqual(harness.removeSettingsCount, 0)
    XCTAssertEqual(harness.state, .blockedRelayUnavailable)
}
```

Add TCP regression, UDP response reinjection with protocol family `.IPv4`, oversized/fragment metric, and stop cleanup tests.

- [ ] **Step 2: Run and verify failure**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS' -only-testing:DroidBridgePacketTunnelTests/PacketTunnelUDPIntegrationTests
```

Expected: FAIL because UDP engine is not connected.

- [ ] **Step 3: Wire packet loop and metrics**

Pass every packet to the unified C engine; the C engine internally routes virtual DNS to DNS callbacks and UDP to UDP callbacks. Reinjected packets are batched up to 32 or 1 ms before `packetFlow.writePackets`. Metrics snapshot adds active UDP flows, bytes, queue drops, sequence gaps, fragment drops, and oversized drops.

- [ ] **Step 4: Run all Packet Tunnel tests**

```bash
xcodebuild test -scheme DroidBridgePacketTunnelTests -destination 'platform=macOS'
```

Expected: B1 and B2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add macos
git commit -m "feat(macos): enable IPv4 UDP full tunnel"
```

---

### Task 6: Host UI capability and provider metrics

**Files:**
- Modify: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayHealth.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/Metrics/TunnelMetricsSnapshot.swift`
- Modify: `macos/HostApp/UI/MenuBarContentView.swift`
- Modify: `macos/HostApp/App/DroidBridgeCoordinatorAdapter.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/B2CapabilityTests.swift`

**Interfaces:**
- Consumes: health capability bit and provider metrics message.
- Produces: TCP-only compatibility mode or TCP+UDP/QUIC UI.

- [ ] **Step 1: Write failing downgrade test**

```swift
func testB1RelayProducesTCPOnlyCompatibilityState() throws {
    let health = try RelayHealth.decode(b1HealthPayload())
    XCTAssertFalse(health.capabilities.contains(.udp4))
    XCTAssertEqual(HostCapabilityState.from(health), .tcpOnly)
}

func testB2MetricsRoundTrip() throws {
    let snapshot = TunnelMetricsSnapshot(activeTCP: 1, activeUDP: 2,
        uploadedBytes: 10, downloadedBytes: 20, udpQueueDrops: 3)
    XCTAssertEqual(snapshot, try JSONDecoder().decode(TunnelMetricsSnapshot.self,
        from: JSONEncoder().encode(snapshot)))
}
```

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter B2CapabilityTests
```

Expected: FAIL because B2 capability/metrics are absent.

- [ ] **Step 3: Implement explicit compatibility UI**

B1 relay displays `TCP only`; B2 relay displays `TCP + UDP/QUIC`. Menu shows active TCP/UDP counts and drop count. It does not show destinations. Connect remains allowed in TCP-only mode and never sends `OPEN_UDP` to a relay without `.udp4`.

- [ ] **Step 4: Run Shared and Host UI tests**

```bash
swift test --package-path macos/Shared
xcodebuild test -scheme DroidBridgeHostTests -destination 'platform=macOS'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add macos
git commit -m "feat(macos): expose B2 UDP capability and metrics"
```
