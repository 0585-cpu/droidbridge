# DroidBridge B2 Android Cellular UDP Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Android relay에 cellular-bound IPv4 UDP sessions와 DBP/1.1 datagram framing을 추가하고 TCP/DNS B1 기능과 함께 안정적으로 운영한다.

**Architecture:** `RelayServer`는 인증된 `OPEN_UDP`를 `UdpRelaySession`에 전달한다. session은 선택된 cellular `Network`에 먼저 bind한 `DatagramSocket` 하나와 세 개의 coroutine을 사용하며, bounded channels가 datagram 경계와 drop-oldest 정책을 보존한다.

**Tech Stack:** Kotlin, Coroutines, Android `Network.bindSocket`, JUnit, Robolectric, AndroidX instrumented tests

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b2-udp-quic-design.md`

## Global Constraints

- UDP socket은 bind 후 connect 순서를 지킨다.
- default/Wi-Fi network fallback을 하지 않는다.
- maximum payload는 1,232 bytes다.
- session default 128, hard 256, TCP+UDP hard 512다.
- idle timeout은 client 요청 30...300초, default 120초다.
- direction별 queue는 64 datagrams 또는 256 KiB다.
- overflow는 drop-oldest다.
- Android `Network` loss 시 B2 UDP session은 종료한다.
- payload, destination, DNS name을 logcat에 기록하지 않는다.

## Review Focus

- `bindSocket` 실패 후 `connect`가 실행되지 않아야 한다.
- socket receive가 block된 상태에서 service stop이 즉시 socket close와 coroutine join으로 끝나야 한다.
- malformed frame이 negative allocation 또는 OOM을 유발하지 않아야 한다.
- queue byte limit과 datagram count limit 중 먼저 도달한 조건이 정확히 적용돼야 한다.
- TCP session limit과 UDP session limit이 합산 hard limit를 우회하지 못해야 한다.

---

### Task 1: Cellular UDP transport abstraction and Android binding

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/network/CellularTransport.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/CellularUdpTransport.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/AndroidCellularUdpTransport.kt`
- Create: `android/app/src/test/java/io/droidbridge/network/AndroidCellularUdpTransportTest.kt`

**Interfaces:**
- Consumes: `CellularNetworkController.currentNetwork()`.
- Produces: `suspend fun openUdp(destination: InetSocketAddress, receiveTimeoutMs: Int): BoundDatagramSocket`.

- [ ] **Step 1: Write failing ordering and no-fallback tests**

```kotlin
@Test
fun `socket binds to cellular before connect`() = runTest {
    val calls = mutableListOf<String>()
    val socket = FakeDatagramSocket(calls)
    val network = FakeNetwork(calls)
    val transport = AndroidCellularUdpTransport({ network }, { socket })

    transport.openUdp(InetSocketAddress("93.184.216.34", 443), 1_000)

    assertEquals(listOf("bind", "connect", "timeout:1000"), calls)
}

@Test
fun `bind failure does not connect or fallback`() = runTest {
    val socket = FakeDatagramSocket().apply { bindFailure = SocketException("EPERM") }
    val transport = AndroidCellularUdpTransport({ FakeNetwork() }, { socket })
    assertFailsWith<CellularBindingException> {
        transport.openUdp(InetSocketAddress("93.184.216.34", 443), 1_000)
    }
    assertFalse(socket.connectCalled)
}
```

- [ ] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.network.AndroidCellularUdpTransportTest
```

Expected: compilation fails because UDP transport types do not exist.

- [ ] **Step 3: Implement the transport**

```kotlin
interface BoundDatagramSocket : Closeable {
    suspend fun send(payload: ByteArray)
    suspend fun receive(maxBytes: Int): ByteArray?
}

interface CellularUdpTransport {
    suspend fun openUdp(
        destination: InetSocketAddress,
        receiveTimeoutMs: Int = 1_000,
    ): BoundDatagramSocket
}
```

The Android implementation creates `DatagramSocket(null)`, invokes `network.bindSocket(socket)`, then `socket.connect(destination)`. Blocking send/receive run on `Dispatchers.IO`; timeout returns `null`, while close/cancellation maps to `CancellationException` rather than reconnecting through another network.

- [ ] **Step 4: Run tests**

```bash
./gradlew testDebugUnitTest --tests io.droidbridge.network.AndroidCellularUdpTransportTest
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): add cellular-bound UDP transport"
```

---

### Task 2: Kotlin DBP datagram codec

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/protocol/DbpTypes.kt`
- Modify: `android/app/src/main/java/io/droidbridge/protocol/DbpCodec.kt`
- Create: `android/app/src/main/java/io/droidbridge/protocol/DatagramFrameCodec.kt`
- Modify: `android/app/src/test/java/io/droidbridge/protocol/DbpCodecTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/protocol/DatagramFrameCodecTest.kt`

**Interfaces:**
- Consumes: canonical B2 protocol vectors.
- Produces: `OpenUdp`, `OpenUdpOk`, `DatagramFrame`, streaming `readFrame`/`writeFrame`.

- [ ] **Step 1: Write failing exact-vector tests**

```kotlin
@Test
fun `decode canonical OPEN_UDP`() {
    val bytes = hex("0101bb045db8d8220078")
    assertEquals(
        OpenUdp(Inet4Address.getByName("93.184.216.34") as Inet4Address, 443, 120),
        DbpCodec.decodeOpenUdp(bytes),
    )
}

@Test
fun `frame rejects payload 1233 before allocation`() = runTest {
    val header = byteArrayOf(0x04, 0xD1.toByte(), 0, 0, 0, 0, 0, 1)
    assertFailsWith<ProtocolViolation> {
        DatagramFrameCodec.readFrame(ByteArrayInputStream(header))
    }
}
```

Also test partial reads of every header split point, reserved byte, flag mask, sequence wrap, EOF halfway through payload, and 1,232-byte round trip.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.protocol.*'
```

Expected: tests fail because UDP types/codecs do not exist.

- [ ] **Step 3: Implement bounded streaming codec**

```kotlin
data class DatagramFrame(
    val flags: UByte,
    val sequence: UInt,
    val payload: ByteArray,
)

object DatagramFrameCodec {
    const val HEADER_SIZE = 8
    const val MAX_PAYLOAD = 1232
    suspend fun readFrame(input: InputStream): DatagramFrame
    suspend fun writeFrame(output: OutputStream, frame: DatagramFrame)
}
```

Read exactly 8 header bytes into a fixed array, validate length/reserved/flags, then allocate at most 1,232 bytes. Do not use `readBytes()` on the untrusted stream.

- [ ] **Step 4: Run tests and fixture parity**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.protocol.*'
```

Expected: PASS for all B1/B2 vectors.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): implement DBP UDP framing"
```

---

### Task 3: UdpRelaySession lifecycle and bounded queues

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/relay/UdpRelaySession.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/DatagramQueue.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/DatagramQueueTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/UdpRelaySessionTest.kt`

**Interfaces:**
- Consumes: authenticated relay streams, `CellularUdpTransport`, metrics sink.
- Produces: `suspend fun UdpRelaySession.run(): UdpCloseReason`.

- [ ] **Step 1: Write failing queue and cancellation tests**

```kotlin
@Test
fun `queue drops oldest when count limit is reached`() {
    val queue = DatagramQueue(maxDatagrams = 2, maxBytes = 1024)
    queue.offer(bytes("one")); queue.offer(bytes("two")); queue.offer(bytes("three"))
    assertContentEquals(bytes("two"), queue.remove())
    assertContentEquals(bytes("three"), queue.remove())
    assertEquals(1, queue.dropped)
}

@Test
fun `service cancellation closes socket and joins loops`() = runTest {
    val socket = BlockingFakeDatagramSocket()
    val session = makeSession(socket)
    val job = launch { session.run() }
    advanceUntilIdle()
    job.cancelAndJoin()
    assertTrue(socket.closed)
    assertEquals(0, session.activeChildrenForTest())
}
```

Add idle timeout, remote EOF, malformed frame, sequence gap metric, 1,232-byte echo, and queue byte-limit tests.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*Udp*'
```

Expected: compilation fails because session and queue do not exist.

- [ ] **Step 3: Implement structured concurrency**

`UdpRelaySession.run()` uses `coroutineScope` and starts exactly three child jobs: relay reader, socket sender, socket receiver/frame writer. Activity is updated on accepted datagram in either direction. A watchdog checks monotonic time every second and throws `UdpIdleTimeout` after the effective timeout. `finally` closes relay socket, cellular socket, queues, then joins child jobs.

- [ ] **Step 4: Run tests with coroutine debug checks**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*Udp*' -Dkotlinx.coroutines.debug
```

Expected: PASS with no leaked child jobs.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): add bounded UDP relay session"
```

---

### Task 4: RelayServer UDP dispatch and combined limits

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelayServer.kt`
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelaySession.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/SessionBudget.kt`
- Modify: `android/app/src/test/java/io/droidbridge/relay/RelayServerTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/SessionBudgetTest.kt`

**Interfaces:**
- Consumes: authenticated DBP message and destination policy.
- Produces: dispatch to TCP, DNS, HEALTH, or UDP; atomic `SessionLease` accounting.

- [ ] **Step 1: Write failing combined-budget tests**

```kotlin
@Test
fun `combined hard limit cannot be bypassed by protocol mix`() {
    val budget = SessionBudget(tcpLimit = 256, udpLimit = 256, totalLimit = 512)
    repeat(256) { budget.acquire(SessionKind.TCP).getOrThrow() }
    repeat(256) { budget.acquire(SessionKind.UDP).getOrThrow() }
    assertTrue(budget.acquire(SessionKind.UDP).isFailure)
    assertTrue(budget.acquire(SessionKind.TCP).isFailure)
}

@Test
fun `unauthenticated connection does not hold UDP lease`() = runTest {
    val server = makeServer(authenticationResult = AuthResult.Failed)
    server.handle(fakeOpenUdpConnection())
    assertEquals(0, server.sessionBudget.snapshot().udp)
}
```

Add destination policy, unsupported capability, lease release after exception, and service stop race tests.

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.RelayServerTest' --tests 'io.droidbridge.relay.SessionBudgetTest'
```

Expected: FAIL because UDP dispatch and budget do not exist.

- [ ] **Step 3: Implement authenticated dispatch**

Acquire a UDP lease only after HELLO authentication and `OPEN_UDP` validation. Apply `DestinationPolicy` before socket creation. Send `OPEN_UDP_OK` with random non-zero server flow ID and effective timeout, then transition to datagram framing. Lease implements `AutoCloseable` and uses an atomic once flag.

- [ ] **Step 4: Run relay tests**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*'
```

Expected: all B1 and B2 relay tests PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): dispatch authenticated UDP sessions"
```

---

### Task 5: UDP metrics, state, and Compose UI

**Files:**
- Modify: `android/app/src/main/java/io/droidbridge/relay/RelayMetrics.kt`
- Modify: `android/app/src/main/java/io/droidbridge/state/RelayState.kt`
- Modify: `android/app/src/main/java/io/droidbridge/ui/RelayViewModel.kt`
- Modify: `android/app/src/main/java/io/droidbridge/ui/RelayScreen.kt`
- Modify: `android/app/src/test/java/io/droidbridge/state/RelayStateTest.kt`
- Modify: `android/app/src/test/java/io/droidbridge/ui/RelayViewModelTest.kt`

**Interfaces:**
- Consumes: session events and atomic counters.
- Produces: privacy-safe UI snapshot with TCP/UDP counts, bytes, drops, capability.

- [ ] **Step 1: Write failing state projection test**

```kotlin
@Test
fun `udp metrics appear without destination or payload`() {
    val snapshot = RelayMetricsSnapshot(
        activeTcp = 2, activeUdp = 3,
        tcpUp = 100, tcpDown = 200,
        udpUp = 300, udpDown = 400,
        udpQueueDrops = 5, udpSequenceGaps = 1,
    )
    val ui = RelayViewModel.project(snapshot)
    assertEquals("3 UDP", ui.udpFlows)
    assertEquals("5", ui.udpDrops)
    assertFalse(ui.toString().contains("93.184"))
}
```

- [ ] **Step 2: Run and verify failure**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.state.*' --tests 'io.droidbridge.ui.*'
```

Expected: FAIL because UDP fields do not exist.

- [ ] **Step 3: Add monotonic counters and concise UI**

Counters use `AtomicLong` and saturate at `Long.MAX_VALUE`. UI shows `TCP`, `UDP`, total upload/download, queue drops, cellular status, and `UDP/QUIC available`. It must not render peer destination data.

- [ ] **Step 4: Run tests**

```bash
./gradlew testDebugUnitTest --tests 'io.droidbridge.state.*' --tests 'io.droidbridge.ui.*'
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add android
git commit -m "feat(android): expose privacy-safe UDP status"
```

---

### Task 6: Real-device cellular UDP binding and cleanup gate

**Files:**
- Create: `android/app/src/androidTest/java/io/droidbridge/network/CellularUdpBindingInstrumentedTest.kt`
- Create: `android/app/src/androidTest/java/io/droidbridge/relay/UdpRelayLifecycleInstrumentedTest.kt`
- Create: `scripts/smoke-android-udp.sh`
- Create: `docs/android-udp-smoke.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: attached Android device and controlled UDP echo endpoint.
- Produces: `make smoke-android-b2-udp` evidence.

- [ ] **Step 1: Write failing instrumentation assertions**

```kotlin
@Test
fun udpSocketUsesSelectedCellularNetworkWhenWifiIsDefault() = runBlocking {
    assumeTrue(hasWifiAndCellular())
    val selected = controller.awaitCellular()
    val socket = transport.openUdp(controlledEchoAddress(), 1_000)
    val observed = socketLocalNetworkHandle(socket)
    assertEquals(selected.networkHandle, observed)
    socket.close()
}

@Test
fun cellularLossClosesEveryUdpSession() = runBlocking {
    val harness = startRelayWithFakeNetworkCallback()
    repeat(8) { harness.openUdpSession() }
    harness.emitNetworkLost()
    assertTrue(harness.awaitActiveUdpCount(0, 3.seconds))
}
```

- [ ] **Step 2: Run and verify the gate is initially incomplete**

```bash
make smoke-android-b2-udp
```

Expected: FAIL because target, tests, and documentation do not exist.

- [ ] **Step 3: Implement the smoke script**

The script verifies one authorized device, installs debug APK, starts relay through an explicit activity intent, requires Wi-Fi and cellular, forwards 27183, runs instrumentation, then confirms no listener remains after Stop. It never toggles APN, tethering, or carrier settings.

- [ ] **Step 4: Run on a real device**

```bash
: "${DROIDBRIDGE_UDP_ECHO_HOST:?set DROIDBRIDGE_UDP_ECHO_HOST to the controlled server}"
: "${DROIDBRIDGE_UDP_ECHO_PORT:?set DROIDBRIDGE_UDP_ECHO_PORT}"
make smoke-android-b2-udp
```

Expected: PASS with evidence containing network handles and counts but no payload/destination history.

- [ ] **Step 5: Commit**

```bash
git add android scripts docs Makefile
git commit -m "test(android): verify cellular UDP relay on device"
```
