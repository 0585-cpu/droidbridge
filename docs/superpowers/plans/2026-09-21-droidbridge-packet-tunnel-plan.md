# DroidBridge macOS Packet Tunnel and TCP Data Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS `NEPacketTunnelProvider`에서 IPv4/TCP와 virtual DNS 패킷을 받아 C/lwIP 사용자 공간 TCP gateway로 종단하고, Android DBP/1 relay를 통해 LTE/5G로 전달하는 fail-closed B1 데이터면을 완성한다.

**Architecture:** Packet Tunnel의 가상 gateway는 `198.18.0.1`, Mac interface는 `198.18.0.2/30`이다. C core는 원래 목적지 TCP flow를 동적 local proxy port로 투명하게 rewrite해 lwIP에 입력하고, lwIP가 수락한 byte stream을 Swift `RelayFlowConnection`에 callback한다. Swift는 flow별 loopback DBP connection을 열어 Android와 raw stream을 중계한다. DNS UDP/TCP 53은 일반 UDP forwarding 없이 별도 bridge로 처리한다.

**Tech Stack:** C17, lwIP pinned gitlink, CMake/CTest/libFuzzer, Swift 6, NetworkExtension, Network.framework, XcodeGen, XCTest, OSLog

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`

## Global Constraints

- virtual interface는 `198.18.0.2/30`, gateway/DNS는 `198.18.0.1`, MTU는 1280이다.
- included route는 `0.0.0.0/0`, excluded route는 `127.0.0.0/8`만 사용한다.
- B1은 IPv4/TCP와 DNS만 처리한다. 일반 UDP, IPv6, ICMP, fragmented IPv4는 전달하지 않는다.
- TCP flow 기본 제한 128, hard limit 256, local rewrite port pool은 20000...20255다.
- lwIP는 `NO_SYS=1` raw API 모드로 사용하며 thread 진입은 하나의 serial engine queue로 제한한다.
- relay flow 하나당 DBP/1 TCP connection 하나를 사용한다.
- relay 연결 전 Mac application data buffer는 flow당 64 KiB, relay inbound/outbound queue는 방향당 256 KiB를 넘지 않는다.
- relay/cellular 장애 시 Packet Tunnel settings를 제거하지 않고 packet을 폐기한다.
- 사용자의 명시적 Disconnect만 `stopVPNTunnel()`을 호출하고 기본 route를 복원한다.
- C/Swift 경계는 payload를 로그하지 않고 callback 수명과 buffer ownership을 문서화한다.
- lwIP license와 source revision은 `THIRD_PARTY_NOTICES.md`와 gitlink로 고정한다.

## Review Focus

- 동일 Mac source port가 서로 다른 원격 목적지에 재사용될 때 local rewrite tuple 충돌 없이 별도 flow로 유지돼야 한다.
- lwIP output packet의 source rewrite와 TCP/IP checksum 재계산이 SYN/ACK, data, FIN, RST 모두에서 정확해야 한다.
- relay가 느리거나 중단될 때 bounded queue가 메모리 무한 증가 대신 backpressure 또는 flow reset으로 끝나야 한다.
- USB/health failure와 packet read loop가 동시에 발생해도 settings가 제거되거나 기본 route로 누출되지 않아야 한다.
- DNS transaction ID, source port, truncation/TCP response, malformed length를 처리하면서 일반 UDP 지원으로 범위가 확장되지 않아야 한다.

---

### Task 1: Pin lwIP and create a deterministic NO_SYS build port

**Files:**
- Add submodule: `core/third_party/lwip`
- Create: `core/ports/lwipopts.h`
- Create: `core/ports/lwip_port.c`
- Create: `core/ports/lwip_port.h`
- Create: `core/src/lwip_adapter.c`
- Create: `core/tests/test_lwip_adapter.c`
- Create: `THIRD_PARTY_NOTICES.md`
- Modify: `core/CMakeLists.txt`
- Modify: `project.yml`

**Interfaces:**
- Consumes: monotonic time and packet emit callbacks from `db_engine_config_t`.
- Produces: `db_lwip_init`, `db_lwip_input`, `db_lwip_poll`, `db_lwip_shutdown`; a single `struct netif` at `198.18.0.1/30`.

- [ ] **Step 1: Write the failing netif initialization test**

```c
static void test_lwip_netif_has_expected_address_and_mtu(void) {
    emitted_packets_t emitted = {0};
    db_lwip_context_t *ctx = db_lwip_init(test_emit, &emitted, test_rand);
    ASSERT_NOT_NULL(ctx);
    ASSERT_IPV4_EQ("198.18.0.1", db_lwip_address(ctx));
    ASSERT_IPV4_EQ("255.255.255.252", db_lwip_netmask(ctx));
    ASSERT_EQ_INT(1280, db_lwip_mtu(ctx));
    db_lwip_shutdown(ctx);
}
```

Add tests that initialization is isolated across repeated create/destroy cycles and that a pbuf chain is flattened into exactly one emitted IPv4 packet.

- [ ] **Step 2: Add the pinned submodule and confirm the test fails before the port exists**

```bash
git submodule add -b STABLE-2_2_1_RELEASE https://github.com/lwip-tcpip/lwip.git core/third_party/lwip
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Debug
cmake --build build/core --parallel
```

Expected: test compilation fails because the adapter symbols are undefined. The submodule gitlink itself records the exact source commit.

- [ ] **Step 3: Implement the minimal lwIP port**

Use these essential `lwipopts.h` values:

```c
#define NO_SYS 1
#define LWIP_IPV4 1
#define LWIP_IPV6 0
#define LWIP_TCP 1
#define LWIP_UDP 0
#define LWIP_RAW 0
#define LWIP_ICMP 0
#define LWIP_DHCP 0
#define LWIP_DNS 0
#define LWIP_NETIF_STATUS_CALLBACK 1
#define LWIP_NETIF_LINK_CALLBACK 1
#define LWIP_TIMERS 1
#define MEM_SIZE (4 * 1024 * 1024)
#define MEMP_NUM_TCP_PCB 320
#define MEMP_NUM_TCP_PCB_LISTEN 260
#define TCP_MSS 1200
#define TCP_WND (64 * 1024)
#define TCP_SND_BUF (64 * 1024)
#define TCP_QUEUE_OOSEQ 1
#define LWIP_TCP_TIMESTAMPS 1
#define CHECKSUM_GEN_IP 1
#define CHECKSUM_GEN_TCP 1
#define CHECKSUM_CHECK_IP 1
#define CHECKSUM_CHECK_TCP 1
```

`sys_now()` returns the engine-injected monotonic millisecond value. `LWIP_RAND()` calls the injected random callback; the macOS implementation later uses `arc4random()`, while tests use deterministic values.

`db_lwip_input()` copies untrusted packet bytes into a bounded pbuf and calls `netif.input`. `netif.output` copies a pbuf chain into a fresh contiguous buffer before invoking the engine callback; it never retains lwIP-owned memory after return.

- [ ] **Step 4: Run C tests and license check**

```bash
make test-core
git -C core/third_party/lwip rev-parse HEAD
test -f core/third_party/lwip/COPYING
```

Expected: adapter tests pass and a 40-hex revision is printed. Record that revision and lwIP BSD license text in `THIRD_PARTY_NOTICES.md`.

- [ ] **Step 5: Commit**

```bash
git add .gitmodules core/third_party/lwip core/ports core/src/lwip_adapter.c core/tests core/CMakeLists.txt project.yml THIRD_PARTY_NOTICES.md
git commit -m "build(core): pin lwip and add no-sys port"
```

### Task 2: Strict IPv4/TCP parsing, checksum, flow key, and transparent rewrite table

**Files:**
- Create: `core/include/droidbridge_packet.h`
- Create: `core/src/ipv4_packet.c`
- Create: `core/src/tcp_packet.c`
- Create: `core/src/checksum.c`
- Create: `core/src/flow_table.c`
- Create: `core/src/tcp_rewrite.c`
- Create: `core/tests/packet_builder.c`
- Create: `core/tests/packet_builder.h`
- Create: `core/tests/test_ipv4_tcp.c`
- Create: `core/tests/test_tcp_rewrite.c`
- Modify: `core/CMakeLists.txt`

**Interfaces:**
- Consumes: raw IPv4 packet bytes.
- Produces: validated `db_ipv4_view_t`, `db_tcp_view_t`, `db_flow_key_t`; rewrite functions `db_rewrite_to_local` and `db_rewrite_from_local`; fixed-capacity flow table.

- [ ] **Step 1: Write failing parse and rewrite tests**

```c
static void test_syn_rewrites_destination_and_output_rewrites_source(void) {
    uint8_t syn[128];
    size_t syn_len = build_tcp_packet(syn, sizeof syn,
        "198.18.0.2", 50123, "93.184.216.34", 443, TCP_SYN, NULL, 0);
    db_flow_mapping_t mapping = {
        .original = flow_key("198.18.0.2", 50123, "93.184.216.34", 443),
        .local_port = 20007,
    };

    ASSERT_EQ_INT(DB_PACKET_OK, db_rewrite_to_local(syn, syn_len, &mapping));
    ASSERT_PACKET_ENDPOINTS(syn, "198.18.0.2", 50123, "198.18.0.1", 20007);
    ASSERT_TRUE(valid_ipv4_checksum(syn, syn_len));
    ASSERT_TRUE(valid_tcp_checksum(syn, syn_len));

    uint8_t syn_ack[128];
    size_t out_len = build_tcp_packet(syn_ack, sizeof syn_ack,
        "198.18.0.1", 20007, "198.18.0.2", 50123, TCP_SYN | TCP_ACK, NULL, 0);
    ASSERT_EQ_INT(DB_PACKET_OK, db_rewrite_from_local(syn_ack, out_len, &mapping));
    ASSERT_PACKET_ENDPOINTS(syn_ack, "93.184.216.34", 443, "198.18.0.2", 50123);
    ASSERT_TRUE(valid_tcp_checksum(syn_ack, out_len));
}
```

Add tests for IPv4 IHL 5...15, total length smaller/larger than buffer, IP/TCP checksum failure, non-TCP, fragment flags/offset, SYN+ACK as first packet, same source port to two remote destinations, pool exhaustion, FIN/RST mapping retention and removal.

- [ ] **Step 2: Run and verify failure**

```bash
make test-core
```

- [ ] **Step 3: Implement bounded parsers and fixed-capacity mapping**

Do not use packed structs or unaligned casts. Parse every field with byte access and validate:

```text
version == 4
IHL >= 5
header bytes <= total length <= provided bytes
protocol == TCP for TCP path
fragment offset == 0 and MF == 0
source == 198.18.0.2 for ingress
TCP data offset >= 5 and within packet
IPv4 and TCP checksum valid
```

Flow key is the full original four-tuple. Use open-addressed fixed tables sized 512 to support 256 mappings below 50% load. Allocate local ports from 20000...20255 and keep reverse lookup by `(localPort, macSourcePort)` so two remote destinations with the same source port remain distinct.

Recompute checksums after every rewrite; zero the TCP checksum field while calculating the pseudo-header checksum.

- [ ] **Step 4: Run tests with sanitizers and repetition**

```bash
cmake -S core -B build/core-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'
cmake --build build/core-asan --parallel
for i in 1 2 3 4 5; do ctest --test-dir build/core-asan --output-on-failure || exit 1; done
```

Expected: all parser/rewrite tests pass five times with no sanitizer output.

- [ ] **Step 5: Commit**

```bash
git add core/include/droidbridge_packet.h core/src core/tests core/CMakeLists.txt
git commit -m "feat(core): parse and rewrite transparent tcp flows"
```

### Task 3: lwIP TCP termination engine and C ABI

**Files:**
- Create: `core/include/droidbridge_core.h`
- Create: `core/src/packet_engine.c`
- Create: `core/src/tcp_bridge.c`
- Create: `core/src/flow_runtime.c`
- Create: `core/tests/test_packet_engine_tcp.c`
- Create: `core/tests/test_flow_limits.c`
- Modify: `core/CMakeLists.txt`

**Interfaces:**
- Consumes: validated/rewrite packet layer and lwIP adapter.
- Produces: approved-spec C ABI plus `db_engine_on_relay_writable`; callbacks for open/send/half-close/close/emit; TCP stream behavior.

- [ ] **Step 1: Write a full synthetic TCP handshake/data test**

The test drives the engine entirely with packet bytes:

```c
static void test_tcp_stream_opens_relay_and_returns_remote_bytes(void) {
    harness_t h = harness_create(128);
    ingest_syn(&h, 50123, "93.184.216.34", 443);
    packet_t syn_ack = h.take_emitted();
    ingest_ack_for(&h, syn_ack);

    ASSERT_EQ_INT(1, h.open_flow_count);
    ASSERT_DESTINATION(h.last_destination, "93.184.216.34", 443);
    db_engine_on_relay_opened(h.engine, h.last_flow_id);

    ingest_payload(&h, "GET / HTTP/1.0\r\n\r\n");
    ASSERT_BYTES_EQ("GET / HTTP/1.0\r\n\r\n", h.relay_outbound);

    db_engine_on_relay_data(h.engine, h.last_flow_id,
        (const uint8_t *)"HTTP/1.0 200 OK\r\n\r\n", 19);
    packet_t response = h.take_emitted();
    ASSERT_PACKET_SOURCE(response, "93.184.216.34", 443);
    ASSERT_TCP_PAYLOAD(response, "HTTP/1.0 200 OK\r\n\r\n");
    harness_destroy(&h);
}
```

Add relay open failure -> RST, data before OPEN_OK buffered to 64 KiB, 64 KiB+1 -> RST, relay send EAGAIN and `on_relay_writable`, inbound queue 256 KiB cap, FIN half-close, RST immediate close, 5-minute timeout, 128 default flow limit and 256 hard cap.

- [ ] **Step 2: Run and verify failure**

```bash
make test-core
```

- [ ] **Step 3: Implement the engine on one serialized thread**

Public configuration and callbacks:

```c
typedef struct {
    uint16_t maximum_flows;
    uint16_t mtu;
    uint64_t idle_timeout_ms;
    db_emit_packet_fn emit_packet;
    db_open_flow_fn open_flow;
    db_send_flow_fn send_flow;
    db_close_flow_fn close_flow;
    db_send_dns_fn send_dns;
    db_random_u32_fn random_u32;
    void *context;
} db_engine_config_t;
```

`db_engine_create` rejects maximumFlows outside 1...256 and MTU other than 1280 for B1. On a new SYN, allocate mapping/listener before feeding the rewritten packet to lwIP. The listener accept callback binds the accepted PCB to `flow_id`, calls `open_flow`, and buffers Mac data until `db_engine_on_relay_opened`.

`tcp_recv` copies at most the allowed queue size, calls `send_flow`, and calls `tcp_recved` only after the callback accepts data. If callback reports temporary full, retain pbuf and retry on `db_engine_on_relay_writable` or tick. Fatal callback errors abort the PCB and emit RST.

`db_engine_on_relay_data` uses `tcp_sndbuf`/`tcp_write(..., TCP_WRITE_FLAG_COPY)` in bounded chunks and queues remaining bytes. `tcp_sent` flushes the queue. Relay close with normal EOF sends FIN; error sends RST.

All public engine functions assert or return an error when invoked reentrantly or from a different registered engine thread in debug builds.

- [ ] **Step 4: Run engine tests and leak checks**

```bash
make test-core
cmake --build build/core-asan --parallel
ASAN_OPTIONS=detect_leaks=1 ctest --test-dir build/core-asan --output-on-failure
```

Expected: handshake/data/limit/timeout tests pass with no leak.

- [ ] **Step 5: Commit**

```bash
git add core/include/droidbridge_core.h core/src core/tests core/CMakeLists.txt
git commit -m "feat(core): terminate tcp flows through lwip"
```

### Task 4: Virtual DNS packet bridge for UDP and TCP port 53

**Files:**
- Create: `core/src/dns_bridge.c`
- Create: `core/src/dns_packet.c`
- Create: `core/tests/test_dns_bridge.c`
- Create: `core/tests/test_dns_tcp_framing.c`
- Modify: `core/include/droidbridge_core.h`
- Modify: `core/src/packet_engine.c`

**Interfaces:**
- Consumes: IPv4 packets whose destination is `198.18.0.1:53`, Android DNS responses via Swift callback.
- Produces: `db_engine_on_dns_response(queryId, response, length)` and correctly addressed UDP/TCP DNS response packets.

- [ ] **Step 1: Write failing DNS packet tests**

```c
static void test_udp_dns_query_round_trip_preserves_transaction_and_source_port(void) {
    harness_t h = harness_create(128);
    packet_t query = build_udp_dns_query("198.18.0.2", 53001, "198.18.0.1", 53, 0x1234, "example.com");
    db_engine_ingest_ipv4(h.engine, query.bytes, query.length);
    ASSERT_EQ_INT(1, h.dns_query_count);
    ASSERT_EQ_HEX(0x1234, dns_transaction_id(h.last_dns_query));

    db_engine_on_dns_response(h.engine, h.last_query_id, dns_a_response(0x1234, "93.184.216.34"));
    packet_t response = h.take_emitted();
    ASSERT_UDP_ENDPOINTS(response, "198.18.0.1", 53, "198.18.0.2", 53001);
    ASSERT_EQ_HEX(0x1234, dns_transaction_id(response.payload));
}
```

Add malformed <12 bytes, mismatched transaction ID, response >4096, query timeout 5 seconds, TCP two-byte framing split across segments, multiple TCP queries sequentially, and non-DNS UDP silently dropped with metric.

- [ ] **Step 2: Run and verify failure**

```bash
make test-core
```

- [ ] **Step 3: Implement bounded DNS bridge**

UDP DNS is intercepted before the general TCP/lwIP path. Store query id, Mac source address/port, original DNS transaction id, transport, and deadline in a fixed table of 128 entries. Call `send_dns`; response must be 12...4096 bytes and transaction id must match.

For TCP DNS to `198.18.0.1:53`, use the existing transparent TCP engine but bind a local DNS handler instead of `open_flow`. Accumulate exactly a two-byte length and one message up to 4096, issue one DNS callback, then return a two-byte length-prefixed response. Support multiple sequential queries but no pipelining beyond four outstanding messages per connection.

A timeout returns a DNS SERVFAIL packet synthesized with the original question when it can be safely parsed; malformed queries are dropped rather than reflected.

- [ ] **Step 4: Run tests and packet checksum validation**

```bash
make test-core
ctest --test-dir build/core-asan --output-on-failure
```

Expected: every emitted UDP/TCP DNS packet has valid IPv4 and transport checksum.

- [ ] **Step 5: Commit**

```bash
git add core/src/dns_bridge.c core/src/dns_packet.c core/include/droidbridge_core.h core/tests
git commit -m "feat(core): bridge virtual dns queries"
```

### Task 5: Swift C bridge and flow-per-connection DBP relay transport

**Files:**
- Create: `macos/PacketTunnel/Core/EngineBridge.swift`
- Create: `macos/PacketTunnel/Core/CoreCallbacks.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayFlowConnection.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayDNSClient.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/NWConnectionProtocol.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/RelayFlowConnectionTests.swift`
- Modify: `project.yml`

**Interfaces:**
- Consumes: C ABI, Pairing Secret, DBP Swift codec.
- Produces: thread-safe `EngineBridge.ingest(packet:)`, flow open/send/half-close/close callbacks, DNS request callback, bounded NWConnection transport.

- [ ] **Step 1: Write failing bounded queue and handshake tests using a fake NWConnection**

```swift
func testFlowDoesNotExposeRawStreamUntilOpenOKAuthenticates() async throws {
    let connection = ScriptedConnection(responses: [.helloOK(valid), .openOK(valid)])
    let flow = RelayFlowConnection(flowId: 7, destination: .ipv4("93.184.216.34", 443),
                                   secret: secret, connection: connection, delegate: delegate)
    try await flow.start()
    XCTAssertEqual(connection.sentFrames.map(\.kind), [.hello, .openTCP])
    XCTAssertEqual(delegate.events, [.opened(7)])
}

func testOutboundQueueOver256KiBReturnsBackpressureWithoutGrowth() {
    let flow = unstartedFlow()
    XCTAssertTrue(flow.enqueueFromCore(Data(repeating: 1, count: 256 * 1024)))
    XCTAssertFalse(flow.enqueueFromCore(Data([2])))
    XCTAssertEqual(flow.bufferedOutboundBytes, 256 * 1024)
}
```

Add wrong HMAC, OPEN_ERROR mapping, EOF half-close, error close, cancel during handshake, flow id reuse, DNS response size/ID validation and secret buffer non-logging tests.

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'RelayFlowConnection|RelayDNS'
```

- [ ] **Step 3: Implement serialized ownership and buffer copying**

`EngineBridge` owns a serial `DispatchQueue(label: "io.droidbridge.packet-engine")`. Every C API call and callback handling occurs on that queue. C callbacks immediately copy inbound pointer bytes into `Data(bytes:count:)`; Swift never retains C pointers.

`RelayFlowConnection.enqueueFromCore` is synchronous and lock-protected so the C callback can return `0` accepted, `1` temporary backpressure, or negative fatal error. It schedules one send pump; NWConnection send completion removes bytes and calls `db_engine_on_relay_writable` on the engine queue.

Start sequence is HELLO -> authenticated HELLO_OK -> OPEN_TCP -> authenticated OPEN_OK -> raw stream. In raw mode, every `receive(minimumIncompleteLength:1, maximumLength:64*1024)` callback copies data into the engine. Normal remote EOF calls `db_engine_on_relay_closed(..., DB_CLOSE_EOF)`; errors call the mapped DBP error.

`RelayDNSClient` opens a short-lived DBP connection per DNS request and enforces a 5-second deadline.

- [ ] **Step 4: Build Swift package tests and extension compile**

```bash
swift test --package-path macos/Shared
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgePacketTunnel \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: relay transport tests pass and extension links against `DroidBridgeCore`.

- [ ] **Step 5: Commit**

```bash
git add macos/PacketTunnel macos/Shared/Sources/DroidBridgeShared/Relay macos/Shared/Tests project.yml
git commit -m "feat(macos): connect packet flows to android relay"
```

### Task 6: Tunnel settings, provider lifecycle, health monitor, and fail-closed controller

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Tunnel/TunnelSettingsDescriptor.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Tunnel/TunnelStateMachine.swift`
- Create: `macos/PacketTunnel/Tunnel/TunnelSettings.swift`
- Create: `macos/PacketTunnel/Tunnel/TunnelController.swift`
- Create: `macos/PacketTunnel/Tunnel/RelayHealthMonitor.swift`
- Create: `macos/PacketTunnel/Metrics/MetricsPublisher.swift`
- Modify: `macos/PacketTunnel/PacketTunnelProvider.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/TunnelSettingsTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/TunnelControllerTests.swift`

**Interfaces:**
- Consumes: runtime config, Keychain secret, engine bridge and health client.
- Produces: `startTunnel`, continuous packet read loop, blocked/reconnect states, App Group metrics snapshots.

- [ ] **Step 1: Write failing settings and failure-transition tests**

```swift
func testSettingsDescriptorIsFullTunnelWithOnlyLoopbackExcluded() throws {
    let descriptor = TunnelSettingsDescriptor.b1
    XCTAssertEqual(descriptor.address, "198.18.0.2")
    XCTAssertEqual(descriptor.subnetMask, "255.255.255.252")
    XCTAssertEqual(descriptor.gateway, "198.18.0.1")
    XCTAssertEqual(descriptor.dnsServers, ["198.18.0.1"])
    XCTAssertEqual(descriptor.includedRoutes, ["0.0.0.0/0"])
    XCTAssertEqual(descriptor.excludedRoutes, ["127.0.0.0/8"])
    XCTAssertEqual(descriptor.mtu, 1280)
}

func testRelayLossEmitsFailClosedEffectsAndKeepsTunnelInstalled() {
    var machine = TunnelStateMachine(state: .running)
    let effects = machine.handle(.relayLost)
    XCTAssertEqual(machine.state, .blocked(.relayUnavailable))
    XCTAssertEqual(effects, [
        .closeAllFlows,
        .dropPackets,
        .scheduleReconnect(delaySeconds: 1),
    ])
    XCTAssertFalse(effects.contains(.removeNetworkSettings))
}
```

Add tests for descriptor validation, start with missing config/secret, health failure before settings, USB loss after start, cellular unavailable status, retry delays 1/2/4 seconds, transition to persistent blocked state after three retries, wake revalidation, and explicit stop emitting `removeNetworkSettings` only after flow shutdown.

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'TunnelSettings|TunnelController'
```

- [ ] **Step 3: Implement provider lifecycle**

`TunnelSettingsDescriptor.b1` is the pure shared source of truth. `TunnelSettings.make(from:)` performs the only mapping to `NEPacketTunnelNetworkSettings`. `TunnelStateMachine` is pure and emits effects; `TunnelController` owns NetworkExtension objects and executes those effects.

`startTunnel` order is fixed:

```text
read/validate runtime config
load 32-byte Keychain secret
authenticated relay health == ready
create EngineBridge
apply NEPacketTunnelNetworkSettings
start packetFlow read loop
start 2-second health monitor
report connected
```

Before settings are applied, any failure calls completion with an error. After settings are applied, health/relay/cellular failures transition to a blocked state: cancel all flow connections, reset the C engine, keep settings, continue reading and count/drop packets. Reconnect attempts occur after 1, 2 and 4 seconds; success creates a fresh engine and resumes ingestion. Exhaustion remains blocked until HostApp sends a reconnect message or explicit Disconnect.

Packet read batches are processed only for `AF_INET`; other protocol families are counted and dropped. The next `readPackets` call is scheduled before processing the current copied batch to avoid receive stalls, but engine ingestion itself remains serialized.

`stopTunnel` stops health monitoring, cancels all connections, destroys engine, clears non-secret runtime status, and invokes completion. It does not delete the pairing Keychain item.

- [ ] **Step 4: Run tests and unsigned build**

```bash
swift test --package-path macos/Shared
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgePacketTunnel \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: lifecycle tests pass and extension compiles.

- [ ] **Step 5: Commit**

```bash
git add macos/PacketTunnel macos/Shared/Sources/DroidBridgeShared/Tunnel macos/Shared/Tests
git commit -m "feat(macos): run fail-closed packet tunnel lifecycle"
```

### Task 7: HostApp VPN manager, provider messaging, and Connect workflow

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/VPN/PacketTunnelManaging.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/VPN/PacketTunnelManager.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/VPN/ProviderMessageClient.swift`
- Create: `macos/HostApp/Tunnel/PacketTunnelViewModelAdapter.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Metrics/TunnelMetricsSnapshot.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/PacketTunnelManagerTests.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/Host/DroidBridgeCoordinatorCore.swift`
- Modify: `macos/Shared/Sources/DroidBridgeShared/Host/HostAppState.swift`
- Modify: `macos/HostApp/App/DroidBridgeCoordinatorAdapter.swift`
- Modify: `macos/HostApp/UI/MenuBarContentView.swift`

**Interfaces:**
- Consumes: prepared relay, runtime configuration store, provider bundle id.
- Produces: Connect/Disconnect/Reconnect actions, VPN status mapping and safe metrics display.

- [ ] **Step 1: Write failing manager and disconnect-order tests**

```swift
func testConnectSavesReloadsThenStartsProvider() async throws {
    let preferences = FakeTunnelPreferences()
    let manager = PacketTunnelManager(preferences: preferences)
    try await manager.connect()
    XCTAssertEqual(preferences.events, ["load", "save", "reload", "start"])
}

func testDisconnectStopsVPNBeforeRemovingADBForward() async throws {
    let h = HostCoordinatorHarness(initial: .connected)
    try await h.coordinator.disconnect()
    XCTAssertEqual(h.events, ["stopVPN", "waitDisconnected", "removeForwards", "deleteRuntimeConfig"])
}
```

Also test existing manager reuse, duplicate configurations, provider error, blocked state metrics, app relaunch while VPN is connected and user reconnect request.

- [ ] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter PacketTunnelManager
```

- [ ] **Step 3: Implement NETunnelProviderManager control**

Use one configuration with provider bundle id `io.droidbridge.macos.PacketTunnel`, localized description `DroidBridge`, server address `Android USB Relay`, and `isEnabled = true`. Load all, keep the first matching manager, remove duplicate matching managers, save, reload, then call `startVPNTunnel(options:)` with no secret in options.

Host Connect order:

```text
verify device + paired secret
create/verify ADB relay forward
authenticated health ready
write runtime config
save/reload VPN preferences
start VPNTunnel
wait connected or blocked status
```

Disconnect order is exactly the test order above so default routing is restored before loopback relay disappears.

Provider messages use compact JSON commands `status`, `metrics`, `reconnect`; responses are capped at 16 KiB and contain no destinations or payload.

- [ ] **Step 4: Run tests and host build**

```bash
swift test --package-path macos/Shared
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 5: Commit**

```bash
git add macos/HostApp macos/Shared/Sources/DroidBridgeShared/Host macos/Shared/Sources/DroidBridgeShared/VPN macos/Shared/Sources/DroidBridgeShared/Metrics macos/Shared/Tests
git commit -m "feat(macos): control full packet tunnel from host app"
```

### Task 8: Packet/parser fuzzing, stress harness, and data-plane preflight gate

**Files:**
- Create: `core/fuzz/fuzz_ipv4_tcp.c`
- Create: `core/fuzz/fuzz_dns_packet.c`
- Create: `core/tests/test_128_flows.c`
- Create: `tools/packet_core_benchmark.c`
- Create: `scripts/verify-data-plane.sh`
- Modify: `core/CMakeLists.txt`
- Modify: `Makefile`
- Modify: `.github/workflows/foundation.yml`

**Interfaces:**
- Consumes: complete C core and Swift unit suites.
- Produces: parser fuzz targets, deterministic 128-flow stress test, pre-signing verification script.

- [ ] **Step 1: Add failing stress expectations**

`test_128_flows.c` must create 128 unique four-tuples, complete handshakes, send 4 KiB in each direction, close half of them with FIN and half with RST, and assert:

```text
active flows returns to 0
open callbacks == 128
fatal closes == 64
normal closes == 64
allocated bytes return to baseline
no local rewrite port remains allocated
```

The 129th concurrent flow under default configuration must receive RST and never call `open_flow`.

- [ ] **Step 2: Build and verify the new targets initially fail**

```bash
cmake -S core -B build/core-fuzz -DDROIDBRIDGE_BUILD_FUZZERS=ON -DCMAKE_C_COMPILER=clang
cmake --build build/core-fuzz --parallel
```

- [ ] **Step 3: Implement fuzz and benchmark targets**

Fuzz raw IPv4/TCP input up to 2048 bytes and DNS packets up to 4096 bytes under ASan/UBSan. The benchmark runs synthetic TCP payload bridging without network I/O for at least 1 GiB total and reports throughput, allocations and maximum resident memory; it is diagnostic, not the real B1 20 Mbps acceptance test.

`verify-data-plane.sh` runs:

```bash
make verify-foundation
make fuzz-smoke
cmake --build build/core --parallel
ctest --test-dir build/core --output-on-failure
swift test --package-path macos/Shared
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost CODE_SIGNING_ALLOWED=NO build
```

- [ ] **Step 4: Run the full preflight**

```bash
./scripts/verify-data-plane.sh
```

Expected: all parser, 128-flow, DNS, Swift and unsigned build checks pass.

- [ ] **Step 5: Commit**

```bash
git add core/fuzz core/tests tools/packet_core_benchmark.c scripts/verify-data-plane.sh Makefile .github/workflows/foundation.yml
git commit -m "test: stress and fuzz packet tunnel data plane"
```

## Packet tunnel completion gate

Run:

```bash
./scripts/verify-data-plane.sh
git status --short
```

This gate proves deterministic code-level behavior only. B1 is not complete until the next plan runs the signed extension on actual Apple Silicon hardware, confirms traffic exits through Android cellular, verifies no route leak on USB/cellular loss, and measures real throughput/RTT.
