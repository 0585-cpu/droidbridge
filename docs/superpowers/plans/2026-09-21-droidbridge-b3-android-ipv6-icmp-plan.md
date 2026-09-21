# DroidBridge B3 Android IPv6, ICMP, and Network Handover Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android relay에 cellular IPv6 capability, IPv6 TCP/UDP, capability 기반 ICMP echo, network generation events, UDP rebind를 추가한다.

**Architecture:** `CellularNetworkController`가 immutable `CellularNetworkSnapshot`과 generation을 `StateFlow`로 제공한다. TCP/UDP transport는 family-agnostic address를 사용한다. ICMP는 NDK ping socket을 `android_setsocknetwork`로 bind할 수 있을 때만 노출한다.

**Tech Stack:** Kotlin, Coroutines/Flow, Android NDK C17, JNI, `android/multinetwork.h`, JUnit, AndroidX instrumentation

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b3-dual-stack-resilience-design.md`

## Global Constraints

- selected cellular `Network` 외 fallback 금지.
- generation은 selected network 교체마다 단조 증가한다.
- IPv6 capability는 global IPv6 address와 socket probe를 함께 사용한다.
- ICMP support는 runtime probe 결과만 신뢰한다.
- external `ping` process와 root를 사용하지 않는다.
- ICMP payload maximum은 1,200 bytes, outstanding 64다.
- network handover에서 TCP는 종료, UDP는 rebind 시도다.
- payload/destination/network subscriber identity를 로그하지 않는다.

## Review Focus

- `onAvailable`, `onLost`, `onCapabilitiesChanged` 순서가 뒤섞여도 generation이 역행하지 않아야 한다.
- IPv6 address scope ID와 link-local address를 public capability로 오판하지 않아야 한다.
- JNI가 exception 경로에서 file descriptor와 native buffer를 누출하지 않아야 한다.
- UDP rebind 중 old/new receive loop가 같은 datagram을 중복 전달하지 않아야 한다.
- event subscriber가 느려도 cellular callback thread를 block하지 않아야 한다.

---

### Task 1: CellularNetworkSnapshot, IPv6, NAT64, and generation

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/network/CellularNetworkController.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/CellularNetworkSnapshot.kt`
- Modify: `android/app/src/test/java/io/droidbridge/network/CellularNetworkControllerTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/network/CellularNetworkSnapshotTest.kt`

**Interfaces:**
- Consumes: `Network`, `NetworkCapabilities`, `LinkProperties` callbacks.
- Produces: `StateFlow<CellularNetworkSnapshot>` with generation, IPv4/IPv6, DNS, NAT64 prefix.

- [ ] **Step 1: Write failing ordering and capability tests**

```kotlin
@Test
fun `generation increments only when selected network identity changes`() = runTest {
    val controller = harness()
    controller.available(network(10), dualStackLinks())
    val first = controller.snapshot.value
    controller.capabilitiesChanged(network(10), validatedCellular())
    assertEquals(first.generation, controller.snapshot.value.generation)
    controller.lost(network(10))
    controller.available(network(11), ipv4OnlyLinks())
    assertEquals(first.generation + 1, controller.snapshot.value.generation)
}

@Test
fun `link local IPv6 alone is not IPv6 internet capability`() {
    val snapshot = CellularNetworkSnapshot.from(network(1), links("fe80::1"), validatedCellular(), 1)
    assertFalse(snapshot.supportsIPv6)
}
```

Add NAT64 /96, no NAT64, stale callback from old network, duplicate onLost, and DNS server family tests.

- [ ] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests 'io.droidbridge.network.CellularNetwork*'
```

Expected: FAIL because snapshot/generation APIs do not exist.

- [ ] **Step 3: Implement serialized selection**

```kotlin
data class CellularNetworkSnapshot(
    val network: Network?,
    val networkHandle: Long?,
    val generation: ULong,
    val isValidated: Boolean,
    val hasGlobalIPv4: Boolean,
    val hasGlobalIPv6: Boolean,
    val dnsServers: List<InetAddress>,
    val nat64Prefix: IpPrefix?,
)
```

Process callbacks on one coroutine dispatcher. Ignore callbacks whose network is not current except an available candidate selection. Global IPv6 excludes any-local, loopback, link-local, site-local, multicast, and ULA.

- [ ] **Step 4: Run tests**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.network.CellularNetwork*'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): model cellular dual-stack capabilities"
```

---

### Task 2: Family-agnostic TCP and UDP transport

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/network/AndroidCellularTransport.kt`
- Modify: `android/app/src/main/java/io/droidbridge/network/AndroidCellularUdpTransport.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/RelayIPAddress.kt`
- Modify: `android/app/src/test/java/io/droidbridge/network/AndroidCellularTransportTest.kt`
- Modify: `android/app/src/test/java/io/droidbridge/network/AndroidCellularUdpTransportTest.kt`

**Interfaces:**
- Consumes: DBP IPv4/IPv6/domain destination and current snapshot.
- Produces: cellular-bound TCP/UDP sockets for both families.

- [ ] **Step 1: Write failing IPv6 and no-fallback tests**

```kotlin
@Test
fun `literal IPv6 TCP uses Inet6Address without DNS`() = runTest {
    val resolver = CountingResolver()
    val transport = makeTcpTransport(resolver = resolver)
    transport.openTcp(RelayIPAddress.IPv6(hex16("26064700470000000000000000001111")), 443)
    assertEquals(0, resolver.calls)
    assertTrue(fakeSocket.connectedAddress is Inet6Address)
}

@Test
fun `IPv6 unavailable returns family error`() = runTest {
    val transport = makeUdpTransport(snapshot = ipv4OnlySnapshot())
    assertFailsWith<AddressFamilyUnavailable> {
        transport.openUdp(ipv6Destination(), 1_000)
    }
    assertFalse(fakeSocketFactory.created)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.network.AndroidCellular*TransportTest'
```

Expected: FAIL because destinations are IPv4-only.

- [ ] **Step 3: Implement sealed address model**

```kotlin
sealed interface RelayIPAddress {
    data class IPv4(val bytes: ByteArray) : RelayIPAddress
    data class IPv6(val bytes: ByteArray) : RelayIPAddress
    data class Domain(val ascii: String) : RelayIPAddress
}
```

Validate exact byte lengths and canonical domain. Before socket creation, verify snapshot supports requested family. Domain resolution uses `snapshot.network.getAllByName()` and applies policy to every result and actual chosen address.

- [ ] **Step 4: Run tests**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.network.AndroidCellular*TransportTest'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): support cellular IPv6 sockets"
```

---

### Task 3: NDK ICMP ping-socket capability probe

**Files:**
- Modify: `android/app/build.gradle.kts`
- Create: `android/app/src/main/cpp/CMakeLists.txt`
- Create: `android/app/src/main/cpp/icmp_native.c`
- Create: `android/app/src/main/cpp/icmp_native.h`
- Create: `android/app/src/main/java/io/droidbridge/icmp/IcmpNative.kt`
- Create: `android/app/src/test/java/io/droidbridge/icmp/IcmpNativeContractTest.kt`

**Interfaces:**
- Consumes: network handle and address family.
- Produces: `probe(family, networkHandle): IcmpCapabilityResult`; native errno category.

- [ ] **Step 1: Write failing Kotlin contract tests**

```kotlin
@Test
fun `unsupported errno maps to unavailable not success`() {
    val native = FakeIcmpNative(errno = OsConstants.EPERM)
    assertEquals(IcmpCapability.Unavailable(IcmpUnavailableReason.Permission),
                 native.probe(AddressFamily.IPV4, 42L))
}

@Test
fun `network binding failure is distinct`() {
    val native = FakeIcmpNative(bindErrno = OsConstants.ENONET)
    assertEquals(IcmpUnavailableReason.NetworkBinding, native.probeV4(42L).reason)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests io.droidbridge.icmp.IcmpNativeContractTest
```

Expected: FAIL because NDK module/contract does not exist.

- [ ] **Step 3: Implement capability-only native entrypoint**

Native flow:

```c
int fd = socket(family, SOCK_DGRAM, protocol);
if (fd < 0) return map_errno(errno);
if (android_setsocknetwork((net_handle_t)network_handle, fd) != 0) { int e = errno; close(fd); return map_bind_errno(e); }
close(fd);
return DB_ICMP_CAPABLE;
```

Build links `android` and `log`, but native code must not log addresses or payloads. JNI validates family 4/6 and positive network handle.

- [ ] **Step 4: Build native library and run tests**

```bash
./gradlew testDebugUnitTest assembleDebug
```

Expected: PASS and APK contains `libdroidbridge_icmp.so` for arm64-v8a.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): probe cellular ICMP ping sockets"
```

---

### Task 4: ICMP echo execution and DBP relay

**Files:**
- Modify: `android/app/src/main/cpp/icmp_native.c`
- Create: `android/app/src/main/java/io/droidbridge/icmp/IcmpEchoExecutor.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/IcmpRelayHandler.kt`
- Create: `android/app/src/test/java/io/droidbridge/icmp/IcmpEchoExecutorTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/IcmpRelayHandlerTest.kt`
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelayServer.kt`

**Interfaces:**
- Consumes: authenticated `ICMP_ECHO_REQUEST`.
- Produces: `ICMP_ECHO_RESPONSE` or `ICMP_ECHO_ERROR` with request ID.

- [ ] **Step 1: Write failing capability and payload tests**

```kotlin
@Test
fun `unsupported family returns explicit error without native send`() = runTest {
    val executor = FakeExecutor(capabilities = setOf(AddressFamily.IPV4))
    val handler = IcmpRelayHandler(executor)
    val response = handler.handle(request(family = AddressFamily.IPV6))
    assertEquals(IcmpErrorCode.UNSUPPORTED, response.error)
    assertEquals(0, executor.sendCount)
}

@Test
fun `payload 1201 is rejected before native allocation`() = runTest {
    val handler = IcmpRelayHandler(FakeExecutor())
    assertFailsWith<ProtocolViolation> { handler.handle(request(payloadSize = 1201)) }
}
```

Add timeout, reply payload mismatch, request ID preservation, TTL clamp 1...255, maximum 64 outstanding, and cancellation close tests.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.icmp.*' --tests 'io.droidbridge.relay.IcmpRelayHandlerTest'
```

Expected: FAIL because executor/handler do not exist.

- [ ] **Step 3: Implement synchronous native echo behind bounded dispatcher**

JNI `nativeEcho` opens a ping socket, binds it to network, sets TTL/hop limit, sends an Echo Request with a native-generated identifier, polls up to requested timeout capped at 5 seconds, validates source/family/type/code, and returns payload plus observed TTL when available. Kotlin uses `Dispatchers.IO.limitedParallelism(8)` and a semaphore of 64 outstanding requests.

- [ ] **Step 4: Run unit and native build tests**

```bash
./gradlew testDebugUnitTest assembleDebug
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): relay capability-based ICMP echo"
```

---

### Task 5: DBP network event subscription

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/protocol/DbpTypes.kt`
- Modify: `android/app/src/main/java/io/droidbridge/protocol/DbpCodec.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/NetworkEventPublisher.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/NetworkEventPublisherTest.kt`
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelayServer.kt`

**Interfaces:**
- Consumes: `StateFlow<CellularNetworkSnapshot>`.
- Produces: authenticated event channel with generation/capability changes.

- [ ] **Step 1: Write failing conflation and HMAC tests**

```kotlin
@Test
fun `slow subscriber receives latest generation without blocking callback`() = runTest {
    val publisher = NetworkEventPublisher(buffer = 1)
    val subscriber = publisher.subscribe()
    repeat(100) { publisher.publish(snapshot(generation = it.toULong())) }
    assertEquals(99uL, subscriber.receive().generation)
}

@Test
fun `event is encoded with fresh nonce and HMAC`() {
    val first = codec.encodeEvent(event(generation = 1u), nonce = 7uL)
    val second = codec.encodeEvent(event(generation = 1u), nonce = 8uL)
    assertNotEquals(first, second)
    assertTrue(authenticator.verify(first))
}
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests io.droidbridge.relay.NetworkEventPublisherTest
```

Expected: FAIL because publisher/event codec do not exist.

- [ ] **Step 3: Implement non-blocking event channels**

Each subscriber has capacity 1 with `DROP_OLDEST`; events carry only generation, capabilities, state, NAT64 prefix, and no addresses/DNS names. Subscriber connection has 30-second heartbeat and closes on authentication expiry or relay stop.

- [ ] **Step 4: Run tests**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.NetworkEventPublisherTest' --tests 'io.droidbridge.protocol.*'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): publish cellular network events"
```

---

### Task 6: UDP rebind and TCP termination on handover

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/relay/UdpRelaySession.kt`
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelaySession.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/NetworkGenerationWatcher.kt`
- Modify: `android/app/src/test/java/io/droidbridge/relay/UdpRelaySessionTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/NetworkHandoverTest.kt`

**Interfaces:**
- Consumes: network snapshot generation changes.
- Produces: UDP socket swap preserving DBP flow; TCP session closure.

- [ ] **Step 1: Write failing handover race tests**

```kotlin
@Test
fun `udp swaps socket once and keeps sequence`() = runTest {
    val harness = udpSessionHarness(generation = 1u)
    harness.deliverFromMac(sequence = 10u, payload = bytes("a"))
    harness.changeNetwork(generation = 2u)
    harness.deliverFromMac(sequence = 11u, payload = bytes("b"))
    assertEquals(listOf(10u, 11u), harness.sentSequences)
    assertEquals(1, harness.oldSocket.closeCount)
    assertEquals(1, harness.newSocket.openCount)
}

@Test
fun `tcp session closes when generation changes`() = runTest {
    val harness = tcpSessionHarness(generation = 1u)
    harness.changeNetwork(generation = 2u)
    assertEquals(TcpCloseReason.NetworkChanged, harness.awaitCloseReason())
}
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*Handover*' --tests 'io.droidbridge.relay.UdpRelaySessionTest'
```

Expected: FAIL because sessions do not observe generation.

- [ ] **Step 3: Implement atomic UDP socket replacement**

Create and bind the new socket before publishing it. A mutex guards the active socket generation. Cancel old receive loop, close old socket, start new receive loop, then allow outbound sends. If new bind fails, close the flow; never resume on default network. TCP session watcher closes both directions immediately on generation change.

- [ ] **Step 4: Run race tests repeatedly**

```bash
for i in $(seq 1 50); do ./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*Handover*' >/dev/null; done
```

Expected: all runs PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): handle cellular network handover"
```

---

### Task 7: Android dual-stack UI, metrics, and real-device gate

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelayMetrics.kt`
- Modify: `android/app/src/main/java/io/droidbridge/state/RelayState.kt`
- Modify: `android/app/src/main/java/io/droidbridge/ui/RelayScreen.kt`
- Modify: `android/app/src/main/java/io/droidbridge/ui/RelayViewModel.kt`
- Create: `android/app/src/androidTest/java/io/droidbridge/network/DualStackCellularInstrumentedTest.kt`
- Create: `android/app/src/androidTest/java/io/droidbridge/icmp/IcmpCapabilityInstrumentedTest.kt`
- Create: `scripts/smoke-android-b3.sh`
- Create: `docs/android-b3-smoke.md`

**Interfaces:**
- Consumes: network snapshot, ICMP probe, relay metrics.
- Produces: device evidence and user-visible capability state.

- [ ] **Step 1: Write failing UI projection test**

```kotlin
@Test
fun `ui states actual family and ICMP capabilities`() {
    val ui = RelayViewModel.project(
        snapshot = dualStackSnapshot(),
        icmp = IcmpCapabilities(v4 = true, v6 = false),
        metrics = emptyMetrics(),
    )
    assertEquals("IPv4 + IPv6", ui.ipFamilies)
    assertEquals("ICMPv4 available · ICMPv6 unavailable", ui.icmpStatus)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.ui.*'
make smoke-android-b3
```

Expected: unit/instrumentation gate fails because B3 UI/script do not exist.

- [ ] **Step 3: Implement UI and smoke sequence**

UI shows generation, IPv4/IPv6, NAT64 present/absent, ICMP4/6 availability, active flow counts, and last handover state. Smoke test compares capability flags with actual IPv4/IPv6 TCP/UDP sockets, runs native ICMP only when capability true, forces a test network generation in instrumentation, and verifies no payload logging.

- [ ] **Step 4: Run on real dual-stack and IPv4-only devices where available**

```bash
: "${DROIDBRIDGE_B3_TEST_HOST:?set DROIDBRIDGE_B3_TEST_HOST to the controlled server}"
make smoke-android-b3
```

Expected: capability matrix accurately reflects each device; unsupported ICMP is PASS when explicitly reported and no false success occurs.

- [ ] **Step 5: Commit**

```bash
git add android scripts docs
git commit -m "test(android): verify B3 dual-stack and ICMP capabilities"
```
