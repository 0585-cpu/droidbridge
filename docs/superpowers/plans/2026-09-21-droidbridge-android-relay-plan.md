# DroidBridge Android Cellular Relay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 루팅되지 않은 Android 8.0+ 단말에서 loopback DBP/1 server를 실행하고, 인증된 Mac 요청을 명시적으로 LTE/5G `Network`에 바인딩된 TCP/DNS socket으로 중계하는 앱을 완성한다.

**Architecture:** UI와 foreground service는 상태·수명주기만 관리한다. `RelayServer`는 `127.0.0.1:27183`에서 세션을 받고 `SessionAuthenticator`, `DestinationPolicy`, `CellularNetworkController`를 조합한다. 최초 페어링은 별도 `127.0.0.1:27184` endpoint에서 P-256 ECDH와 양쪽 SAS 승인을 수행하며, B1은 한 대의 Mac만 등록하고 새 페어링 시 기존 등록을 폐기한다.

**Tech Stack:** Kotlin 2.4.20, Android Gradle Plugin 9.4.0, Gradle 9.6.0, JDK 17, compile/target SDK 36, min SDK 26, Jetpack Compose, Coroutines 1.10.2, Android Keystore, JUnit/Robolectric/AndroidX Test

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`

## Global Constraints

- Android application id는 `io.droidbridge.android`, namespace는 `io.droidbridge`다.
- relay는 `127.0.0.1:27183`, pairing은 `127.0.0.1:27184`에만 bind한다.
- B1은 등록된 Mac 한 대만 유지한다. 새 Mac 승인 시 기존 Pairing Secret과 peer id를 즉시 폐기한다.
- relay foreground service는 사용자가 화면의 Start를 누른 뒤에만 시작하며 부팅·background receiver로 자동 시작하지 않는다.
- foreground service type은 `connectedDevice`이고 지속 알림을 표시한다.
- 외부 TCP socket은 `Network.getSocketFactory()`로 만들고 DNS UDP/TCP socket은 선택한 cellular `Network`에 bind한다.
- domain은 cellular `Network.getAllByName()`으로 해석하고 반환된 모든 주소와 실제 connect 주소에 목적지 정책을 적용한다.
- Wi-Fi나 다른 기본 네트워크로 자동 fallback하지 않는다.
- connect timeout 10초, authentication timeout 3초, idle timeout 5분, half-close grace 10초다.
- 기본 동시 session 128, hard limit 256, 방향별 buffer 64 KiB다.
- logcat에 secret, packet payload, DNS name, HTTP/TLS metadata를 기록하지 않는다.

## Review Focus

- `Network.onLost()`와 capability 변경이 session 생성과 정확히 경쟁해도 새 flow가 Wi-Fi/default network로 열리지 않아야 한다.
- domain이 public·private IP를 함께 반환하면 하나를 임의 선택하지 말고 전체를 정책 검사한 뒤 public 주소만 시도하며 실제 connect 대상도 재검사해야 한다.
- HELLO에서 등록한 nonce는 같은 connection의 OPEN/DNS에는 허용하지만 새 connection에서 재사용하면 거부해야 한다.
- service stop, process death, cellular loss 시 ServerSocket·NetworkCallback·client socket·coroutine이 모두 정리돼야 한다.
- pairing endpoint는 60초 후 닫히고 양쪽 승인 완료 전에는 secret을 영구 저장하지 않아야 한다.

---

### Task 1: Android project, dependency pins, and observable state model

**Files:**
- Create: `android/settings.gradle.kts`
- Create: `android/build.gradle.kts`
- Create: `android/gradle.properties`
- Create: `android/gradle/libs.versions.toml`
- Create: `android/gradle/wrapper/gradle-wrapper.properties`
- Create: `android/app/build.gradle.kts`
- Create: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/main/java/io/droidbridge/state/RelayState.kt`
- Create: `android/app/src/test/java/io/droidbridge/state/RelayStateTest.kt`

**Interfaces:**
- Consumes: Gradle/JDK/API floors from the approved spec.
- Produces: `RelayState`, `RelayStatus`, `CellularStatus`, build commands `./gradlew testDebugUnitTest` and `./gradlew assembleDebug`.

- [x] **Step 1: Write the failing state transition test**

```kotlin
class RelayStateTest {
    @Test
    fun `cellular loss while running becomes blocked without stopping service`() {
        val initial = RelayState(
            relayStatus = RelayStatus.RUNNING,
            cellularStatus = CellularStatus.AVAILABLE,
            activeFlows = 4,
            uploadedBytes = 100,
            downloadedBytes = 200,
            lastError = null,
        )

        val result = initial.onCellularLost("network lost")

        assertEquals(RelayStatus.BLOCKED_CELLULAR, result.relayStatus)
        assertEquals(CellularStatus.UNAVAILABLE, result.cellularStatus)
        assertEquals(0, result.activeFlows)
        assertEquals("network lost", result.lastError)
    }
}
```

Also test Start from STOPPED, stop from every state, flow count never below zero, and counters use saturating non-negative values.

- [x] **Step 2: Run and verify failure**

Run:

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.state.RelayStateTest
```

Expected: build or compilation fails because project/state types do not exist.

- [x] **Step 3: Create the pinned build and minimal immutable state model**

Use these exact version pins in `libs.versions.toml`:

```toml
[versions]
agp = "9.4.0"
kotlin = "2.4.20"
compose-bom = "2026.08.00"
activity-compose = "1.12.0"
lifecycle = "2.10.0"
coroutines = "1.10.2"
junit4 = "4.13.2"
robolectric = "4.16"
androidx-test-core = "1.7.0"
```

Use Gradle distribution `gradle-9.6.0-bin.zip`, Java toolchain 17, `compileSdk = 36`, `targetSdk = 36`, `minSdk = 26`, and Compose compiler plugin version `2.4.20`.

`RelayState.kt` must define:

```kotlin
enum class RelayStatus { STOPPED, STARTING, RUNNING, BLOCKED_CELLULAR, STOPPING, FAILED }
enum class CellularStatus { UNAVAILABLE, REQUESTING, AVAILABLE, LOST }

data class RelayState(
    val relayStatus: RelayStatus = RelayStatus.STOPPED,
    val cellularStatus: CellularStatus = CellularStatus.UNAVAILABLE,
    val carrierName: String? = null,
    val pairedMacName: String? = null,
    val activeFlows: Int = 0,
    val uploadedBytes: Long = 0,
    val downloadedBytes: Long = 0,
    val lastError: String? = null,
)
```

Keep transition methods pure so tests do not need Android framework classes.

- [x] **Step 4: Run unit build and lint**

```bash
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
```

Expected: all tasks pass and `app-debug.apk` is produced.

- [x] **Step 5: Commit**

```bash
git add android
git commit -m "build(android): scaffold relay application"
```

### Task 2: Kotlin DBP codec, HMAC session authentication, and replay cache

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/protocol/DbpTypes.kt`
- Create: `android/app/src/main/java/io/droidbridge/protocol/DbpCodec.kt`
- Create: `android/app/src/main/java/io/droidbridge/security/SessionAuthenticator.kt`
- Create: `android/app/src/main/java/io/droidbridge/security/NonceReplayCache.kt`
- Create: `android/app/src/test/java/io/droidbridge/protocol/DbpCodecTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/security/SessionAuthenticatorTest.kt`
- Add test resource: `android/app/src/test/resources/dbp-v1.json`

**Interfaces:**
- Consumes: `protocol/test-vectors/dbp-v1.json` copied byte-for-byte into test resources.
- Produces: `DbpCodec.readHeader`, `DbpCodec.writeHeader`, `DbpCodec.readOpenTcp`, `SessionAuthenticator.acceptHello`, `AuthenticatedSession.verifyFollowup`.

- [x] **Step 1: Write fixture and replay tests**

```kotlin
@Test
fun `domain OPEN_TCP fixture decodes byte for byte`() {
    val vector = fixture("open_domain_443")
    val message = DbpCodec.decode(vector.wireHex.hexToBytes())
    assertEquals(DbpMessageType.OPEN_TCP, message.header.type)
    assertEquals(OpenDestination.Domain("example.com", 443), message.payload)
}

@Test
fun `nonce may continue in the authenticated connection but not in a new connection`() {
    val clock = MutableClock(1_700_000_000)
    val cache = NonceReplayCache(maxEntries = 1024, ttlSeconds = 300, clock = clock)
    val authenticator = SessionAuthenticator(secret, cache, clock)
    val hello = signedHello(clientNonce = 7, timestamp = clock.epochSeconds())

    val session = authenticator.acceptHello(hello)
    session.verifyFollowup(signedHealth(clientNonce = 7, serverNonce = session.serverNonce))
    assertFailsWith<DbpAuthenticationException> { authenticator.acceptHello(hello) }
}
```

Add tests for 120 seconds accepted, 121 rejected, wrong HMAC, unknown type, non-zero flags, bad header length, HELLO with non-empty payload, constant-time comparison path, replay cache eviction at 1024, and body over 4096 bytes.

- [x] **Step 2: Run tests and confirm failure**

```bash
cd android
./gradlew testDebugUnitTest --tests 'io.droidbridge.protocol.*' --tests 'io.droidbridge.security.*'
```

Expected: undefined codec/authenticator symbols.

- [x] **Step 3: Implement strict wire handling and connection-scoped auth**

Use `ByteBuffer.order(ByteOrder.BIG_ENDIAN)` on a private copied 64-byte header; never call `readBytes()` with a length obtained from the peer before checking the 4096-byte control payload ceiling.

Public signatures:

```kotlin
object DbpCodec {
    const val HEADER_SIZE = 64
    const val MAX_CONTROL_PAYLOAD = 4096
    fun decodeHeader(bytes: ByteArray): DbpHeader
    fun encodeHeader(header: DbpHeader, hmac: ByteArray): ByteArray
    fun decodeOpenTcp(payload: ByteArray): OpenDestination
    fun encodeError(code: DbpErrorCode): ByteArray
}

class SessionAuthenticator(
    private val secretProvider: () -> ByteArray?,
    private val replayCache: NonceReplayCache,
    private val clock: EpochClock,
    private val random: SecureRandom = SecureRandom(),
) {
    fun acceptHello(header: DbpHeader, payload: ByteArray): AuthenticatedSession
}
```

`acceptHello` requires flags zero, an empty HELLO payload, zero `serverNonce`, valid timestamp/HMAC, and an unseen non-zero `clientNonce`; then generates a non-zero random 64-bit `serverNonce`. `AuthenticatedSession.verifyFollowup` requires flags zero, the exact client/server nonce pair and HMAC but does not insert a second replay entry. Payload size is derived from the message-specific prefix; no unbounded generic body read is permitted.

Use `MessageDigest.isEqual()` for HMAC comparison and `Mac.getInstance("HmacSHA256")` for signing.

- [x] **Step 4: Run tests and fixture drift check**

```bash
cp protocol/test-vectors/dbp-v1.json android/app/src/test/resources/dbp-v1.json
cd android
./gradlew testDebugUnitTest
cmp ../protocol/test-vectors/dbp-v1.json app/src/test/resources/dbp-v1.json
```

Expected: tests pass and `cmp` emits no output.

- [x] **Step 5: Commit**

```bash
git add android/app/src/main/java/io/droidbridge/protocol android/app/src/main/java/io/droidbridge/security android/app/src/test
git commit -m "feat(android): authenticate dbp1 sessions"
```

### Task 3: Android destination policy and DNS-rebinding-safe resolution

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/policy/DestinationPolicy.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/ResolvedDestination.kt`
- Create: `android/app/src/test/java/io/droidbridge/policy/DestinationPolicyTest.kt`
- Add test resource: `android/app/src/test/resources/destination-policy.json`

**Interfaces:**
- Consumes: `protocol/test-vectors/destination-policy.json`.
- Produces: `DestinationPolicy.evaluate(InetAddress)`, `DestinationPolicy.filterResolved(domain, addresses)`.

- [x] **Step 1: Write failing policy and mixed-answer tests**

```kotlin
@Test
fun `mixed public and private DNS answer retains only public addresses`() {
    val answers = listOf(
        InetAddress.getByName("93.184.216.34"),
        InetAddress.getByName("192.168.1.10"),
    )
    val filtered = policy.filterResolved("example.test", answers)
    assertEquals(listOf("93.184.216.34"), filtered.map { it.hostAddress })
}

@Test
fun `all blocked DNS answers fail closed`() {
    val answers = listOf(InetAddress.getByName("127.0.0.1"), InetAddress.getByName("10.0.0.2"))
    assertFailsWith<DestinationDeniedException> {
        policy.filterResolved("rebind.test", answers)
    }
}
```

Load every boundary fixture and compare its expected result.

- [x] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.policy.DestinationPolicyTest
```

- [x] **Step 3: Implement integer-mask IPv4 policy**

Reject non-IPv4 addresses in B1 with `UNSUPPORTED_ADDRESS_FAMILY`. Convert `Inet4Address.address` to an unsigned `Long` and use a static ordered CIDR list matching the C implementation. `filterResolved` must remove denied addresses, preserve the resolver order of allowed addresses, and throw when none remain.

At socket connection time call `evaluate()` again on the exact `InetAddress` passed to `Socket.connect()`; do not trust only the original DNS list.

- [x] **Step 4: Run fixture parity checks**

```bash
cp protocol/test-vectors/destination-policy.json android/app/src/test/resources/destination-policy.json
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.policy.DestinationPolicyTest
cmp ../protocol/test-vectors/destination-policy.json app/src/test/resources/destination-policy.json
```

- [x] **Step 5: Commit**

```bash
git add android/app/src/main/java/io/droidbridge/policy android/app/src/main/java/io/droidbridge/network/ResolvedDestination.kt android/app/src/test
git commit -m "feat(android): block private and reserved relay destinations"
```

### Task 4: P-256 pairing endpoint and Keystore-protected single-peer store

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/pairing/PairingProtocol.kt`
- Create: `android/app/src/main/java/io/droidbridge/pairing/PairingServer.kt`
- Create: `android/app/src/main/java/io/droidbridge/pairing/PairingCoordinator.kt`
- Create: `android/app/src/main/java/io/droidbridge/security/PairingSecretStore.kt`
- Create: `android/app/src/main/java/io/droidbridge/security/AndroidPairingSecretStore.kt`
- Create: `android/app/src/test/java/io/droidbridge/pairing/PairingProtocolTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/security/PairingSecretStoreTest.kt`

**Interfaces:**
- Consumes: none from runtime DBP beyond the 256-bit resulting secret.
- Produces: pairing port 27184; `PairingCoordinator.openWindow(duration = 60.seconds)`; `StateFlow<PairingUiState>`; exactly one `PairedPeer`.

- [x] **Step 1: Write deterministic key agreement and expiry tests**

```kotlin
@Test
fun `both roles derive same secret and six digit SAS`() {
    val mac = deterministicParty(seed = 1)
    val phone = deterministicParty(seed = 2)
    val transcript = PairingTranscript.create(mac.hello, phone.hello)

    val macResult = PairingProtocol.derive(mac.privateKey, phone.publicKey, transcript)
    val phoneResult = PairingProtocol.derive(phone.privateKey, mac.publicKey, transcript)

    assertContentEquals(macResult.secret, phoneResult.secret)
    assertEquals(macResult.sas, phoneResult.sas)
    assertTrue(macResult.sas.matches(Regex("[0-9]{6}")))
}

@Test
fun `pairing window expires without persisting secret`() = runTest {
    coordinator.openWindow(60.seconds)
    testScheduler.advanceTimeBy(60_001)
    assertEquals(PairingUiState.Closed, coordinator.state.value)
    assertNull(store.load())
}
```

Also test one-sided approval, transcript tampering, invalid public key, frame above 8192 bytes, and new peer atomically replacing the old peer.

- [x] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests 'io.droidbridge.pairing.*' --tests 'io.droidbridge.security.PairingSecretStoreTest'
```

- [x] **Step 3: Implement the exact pairing protocol**

Use a 4-byte big-endian JSON frame length capped at 8192 bytes. The hello object contains:

```json
{"version":1,"role":"mac","peerId":"uuid","displayName":"MacBook","publicKey":"base64-x963","nonce":"base64-32"}
```

Generate `secp256r1` ephemeral keys. Build the transcript as:

```text
"DROIDBRIDGE-PAIR-1" || macHelloCanonicalJson || androidHelloCanonicalJson
```

Derive 32 bytes with HKDF-SHA256 where salt is `macNonce || androidNonce` and info is UTF-8 `DroidBridge DBP/1 Pairing`. Compute SAS as unsigned big-endian first four bytes of `SHA-256(transcript)`, modulo 1,000,000, padded to six digits.

Both sides send an approval frame containing `sessionId`, `approved`, and:

```text
HMAC(secret, role || 0x00 || SHA-256(transcript))
```

Persist only after both proofs validate and Android user approved. `PairingServer` binds loopback port 27184 and closes after one completed attempt or 60 seconds.

- [x] **Step 4: Protect the secret at rest**

`AndroidPairingSecretStore` generates an AES-256-GCM key named `io.droidbridge.pairing.storage.v1` in `AndroidKeyStore`, encrypts a compact peer record into private `SharedPreferences`, uses random 12-byte IV and peer id as AAD, and overwrites the previous encrypted blob in one `edit(commit = true)` transaction. Never expose a method that returns the secret as String.

Run:

```bash
cd android
./gradlew testDebugUnitTest
```

Expected: pairing and storage tests pass.

- [x] **Step 5: Commit**

```bash
git add android/app/src/main/java/io/droidbridge/pairing android/app/src/main/java/io/droidbridge/security android/app/src/test
git commit -m "feat(android): pair one mac with ecdh and keystore storage"
```

### Task 5: Cellular network controller and bound TCP connector

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/network/CellularNetworkController.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/CellularTransport.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/AndroidCellularTransport.kt`
- Create: `android/app/src/test/java/io/droidbridge/network/CellularNetworkControllerTest.kt`
- Create: `android/app/src/androidTest/java/io/droidbridge/network/CellularBindingInstrumentedTest.kt`

**Interfaces:**
- Consumes: `DestinationPolicy`.
- Produces: `StateFlow<CellularState>`; `suspend fun connectTcp(destination): Socket`; `fun currentNetwork(): Network?`; `fun currentDnsServers(): List<InetAddress>`.

- [x] **Step 1: Write race and no-fallback tests around a framework adapter**

Define an injectable interface:

```kotlin
interface ConnectivityFacade {
    fun requestCellular(callback: CellularCallback)
    fun unregister(callback: CellularCallback)
    fun resolve(network: NetworkHandle, domain: String): List<InetAddress>
    fun openSocket(network: NetworkHandle): Socket
}
```

Test that `connectTcp()` throws `CellularUnavailableException` before `onAvailable`, after `onLost`, and during replacement; verify the fake default/Wi-Fi socket factory is never invoked.

- [x] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.network.CellularNetworkControllerTest
```

- [x] **Step 3: Implement lifecycle and socket binding**

Build this request exactly:

```kotlin
NetworkRequest.Builder()
    .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
    .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    .build()
```

Store a generation number with each available `Network`. `connectTcp()` snapshots `(network, generation)`, resolves domains through `network.getAllByName`, filters addresses, creates a fresh socket through `network.socketFactory.createSocket()`, rechecks generation and destination policy, then calls `connect(address, 10_000)`. If generation changed at any point, close and fail rather than retry through another interface.

On `onLost` atomically clear the network, publish `CellularState.Lost`, and call registered flow-cancellation listeners.

- [x] **Step 4: Add a real-device binding assertion**

The instrumentation test starts only when a cellular `Network` exists, opens a TCP socket through `AndroidCellularTransport`, then asserts `ConnectivityManager.getNetworkCapabilities(network)` contains `TRANSPORT_CELLULAR`. It must not assert a public service response or consume large traffic.

Run:

```bash
cd android
./gradlew testDebugUnitTest assembleDebug
./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=io.droidbridge.network.CellularBindingInstrumentedTest
```

Expected: unit tests always pass; instrumentation passes on a connected device with active mobile data or is explicitly skipped with `Assume.assumeTrue` when no cellular network exists.

- [x] **Step 5: Commit**

```bash
git add android/app/src/main/java/io/droidbridge/network android/app/src/test android/app/src/androidTest
git commit -m "feat(android): bind outbound sockets to cellular network"
```

### Task 6: Cellular DNS UDP-to-TCP forwarder

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/network/CellularDnsForwarder.kt`
- Create: `android/app/src/main/java/io/droidbridge/network/DnsWire.kt`
- Create: `android/app/src/test/java/io/droidbridge/network/CellularDnsForwarderTest.kt`

**Interfaces:**
- Consumes: selected cellular network and its `LinkProperties.dnsServers`.
- Produces: `suspend fun query(packet: ByteArray): ByteArray`; total deadline 5 seconds, per-server UDP deadline 2 seconds, TCP fallback on TC bit.

- [x] **Step 1: Write failing fallback and validation tests**

```kotlin
@Test
fun `truncated UDP response retries same server over TCP`() = runTest {
    val transport = FakeDnsTransport(
        udpResponses = listOf(dnsResponse(tc = true)),
        tcpResponses = listOf(dnsResponse(tc = false)),
    )
    val response = CellularDnsForwarder(transport, clock).query(validQuery())
    assertFalse(DnsWire.isTruncated(response))
    assertEquals(listOf("udp:1.1.1.1", "tcp:1.1.1.1"), transport.calls)
}
```

Also test mismatched transaction ID, malformed packet under 12 bytes, response over 4096 bytes, first server timeout then second success, and total 5-second deadline.

- [x] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.network.CellularDnsForwarderTest
```

- [x] **Step 3: Implement network-bound DNS transport**

For UDP, create `DatagramSocket(null)`, call `network.bindSocket(socket)`, connect to server port 53, send at most 4096 bytes, and verify transaction id plus QR bit. For TCP, create through `network.socketFactory`, connect to port 53, prefix query with two-byte length, and use `readFully` with maximum 4096 bytes.

Do not cache names and do not log query bytes. Return `DnsFailure` with one of `MALFORMED`, `NO_SERVERS`, `TIMEOUT`, `ID_MISMATCH`, `IO_ERROR`.

- [x] **Step 4: Run tests**

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.network.CellularDnsForwarderTest
```

Expected: all DNS tests pass under virtual time.

- [x] **Step 5: Commit**

```bash
git add android/app/src/main/java/io/droidbridge/network android/app/src/test/java/io/droidbridge/network
git commit -m "feat(android): forward dns over selected cellular network"
```

### Task 7: Loopback RelayServer, authenticated session handler, and raw TCP bridge

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/relay/RelayServer.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/RelaySession.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/StreamBridge.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/RelayMetrics.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/RelayServerTest.kt`
- Create: `android/app/src/test/java/io/droidbridge/relay/StreamBridgeTest.kt`

**Interfaces:**
- Consumes: authenticator, single peer store, destination policy, cellular TCP connector, DNS forwarder.
- Produces: DBP runtime port 27183, `StateFlow<RelayMetricsSnapshot>`, and the canonical `HEALTH_RESPONSE` payload defined in `protocol/dbp-v1.md`.

- [x] **Step 1: Write failing end-to-end loopback tests using fake cellular sockets**

Test these exact paths:

```kotlin
@Test
fun `OPEN_TCP bridges bytes and applies half close`() = runTest {
    val remote = FakeDuplexSocket(response = "pong".encodeToByteArray())
    val server = relayServer(remoteSocket = remote)
    server.start(port = 0)

    DbpTestClient(server.port, secret).use { client ->
        client.hello()
        client.openDomain("example.com", 443)
        client.write("ping".encodeToByteArray())
        client.shutdownOutput()
        assertContentEquals("pong".encodeToByteArray(), client.readAll())
    }

    assertContentEquals("ping".encodeToByteArray(), remote.received)
    assertTrue(remote.outputHalfClosed)
}
```

Add wrong secret, private IP, session 129, auth timeout, idle timeout, cellular loss while active, DNS query, health, malformed OPEN, and server bind address assertion equal to loopback.

- [x] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*'
```

- [x] **Step 3: Implement bounded server and session state machine**

`RelayServer.start()` must bind using:

```kotlin
ServerSocket().apply {
    reuseAddress = false
    bind(InetSocketAddress(InetAddress.getLoopbackAddress(), requestedPort), 128)
}
```

Use two independent bounds. `connectionSlots = Semaphore(256)` limits all accepted/authenticating sockets and prevents unauthenticated connection exhaustion. `flowSlots = Semaphore(config.maximumFlows)` defaults to 128 and is validated in 1...256. Each connection gets a 3-second initial read deadline. The first message must be HELLO; the second must be exactly one of OPEN_TCP, DNS_QUERY, or HEALTH. Acquire a flow slot only after an authenticated `OPEN_TCP`; when none is available, return authenticated `OPEN_ERROR(SESSION_LIMIT)` and close. HEALTH and DNS do not consume a TCP-flow slot but remain subject to the global connection bound.

Encode `HEALTH_RESPONSE` exactly as the foundation fixture: status u8, active/max sessions u16, uploaded/downloaded bytes u64, carrier-name length u8, then 0...63 UTF-8 bytes. Clamp no field; reject impossible internal values before encoding so cross-language tests expose accounting bugs.

After `OPEN_OK`, call `StreamBridge.copyBidirectional` with two 64 KiB buffers. EOF in one direction invokes `Socket.shutdownOutput()` on the opposite side; the remaining direction receives at most 10 seconds before full close. A 5-minute no-byte idle timer closes both sides. On cellular loss, cancel every session job and close every socket.

Metrics use atomic counters and never expose destination hostnames or payload.

- [x] **Step 4: Run server tests under repetition**

```bash
cd android
for i in 1 2 3 4 5; do ./gradlew testDebugUnitTest --tests 'io.droidbridge.relay.*' || exit 1; done
```

Expected: five consecutive passes with no leaked coroutine warning.

- [x] **Step 5: Commit**

```bash
git add android/app/src/main/java/io/droidbridge/relay android/app/src/test/java/io/droidbridge/relay
git commit -m "feat(android): serve authenticated cellular tcp relay"
```

### Task 8: Foreground service, Compose control screen, and persistent notification

**Files:**
- Create: `android/app/src/main/java/io/droidbridge/MainActivity.kt`
- Create: `android/app/src/main/java/io/droidbridge/ui/RelayScreen.kt`
- Create: `android/app/src/main/java/io/droidbridge/ui/RelayViewModel.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/RelayForegroundService.kt`
- Create: `android/app/src/main/java/io/droidbridge/relay/RelayServiceController.kt`
- Create: `android/app/src/main/res/values/strings.xml`
- Modify: `android/app/src/main/AndroidManifest.xml`
- Create: `android/app/src/test/java/io/droidbridge/ui/RelayViewModelTest.kt`
- Create: `android/app/src/androidTest/java/io/droidbridge/relay/RelayForegroundServiceTest.kt`

**Interfaces:**
- Consumes: pairing coordinator, relay server, network state and metrics.
- Produces: explicit Start/Stop/Pair New Mac/Forget Mac actions; foreground notification; human-readable safe error states.

- [x] **Step 1: Write failing ViewModel action tests**

```kotlin
@Test
fun `start is disabled until a peer exists and cellular request can begin`() = runTest {
    val vm = RelayViewModel(fakeController, emptyStore, fakePairing)
    assertFalse(vm.uiState.value.canStart)
    vm.onStartClicked()
    assertEquals(0, fakeController.startCalls)
}

@Test
fun `forget mac stops relay before deleting secret`() = runTest {
    val vm = RelayViewModel(fakeController, populatedStore, fakePairing)
    vm.onForgetMacClicked()
    assertEquals(listOf("stop", "forget"), fakeController.events)
}
```

- [x] **Step 2: Run and verify failure**

```bash
cd android
./gradlew testDebugUnitTest --tests io.droidbridge.ui.RelayViewModelTest
```

- [x] **Step 3: Implement service and manifest contract**

Declare only these relevant permissions:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

Service declaration:

```xml
<service
    android:name=".relay.RelayForegroundService"
    android:exported="false"
    android:foregroundServiceType="connectedDevice" />
```

On Start action, call `startForeground()` before cellular request/server startup. On Stop action, close server, unregister network callback, stop foreground, then stop self. The notification text shows only `Running`, `Blocked: cellular unavailable`, active flow count, and byte totals.

The Compose screen displays all spec fields, six-digit SAS only during a live pairing window, and explicit approval/reject buttons. It never displays or copies the Pairing Secret.

- [x] **Step 4: Run unit, instrumentation, lint, and APK build**

```bash
cd android
./gradlew testDebugUnitTest lintDebug assembleDebug
./gradlew connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=io.droidbridge.relay.RelayForegroundServiceTest
```

Expected: service enters foreground, binds only loopback, and stops cleanly.

- [x] **Step 5: Commit**

```bash
git add android/app/src/main android/app/src/test android/app/src/androidTest
git commit -m "feat(android): add explicit foreground relay controls"
```

### Task 9: Actual-device pairing and relay smoke gate

**Files:**
- Create: `tools/pairing_probe.py`
- Create: `tools/tests/test_pairing_probe.py`
- Create: `tools/requirements-dev.txt`
- Create: `scripts/install-android-debug.sh`
- Create: `scripts/smoke-android-relay.sh`
- Create: `docs/android-debug-smoke.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: pairing port 27184, relay port 27183, Android debug APK, DBP probe.
- Produces: a repeatable manual+automated smoke procedure proving ADB loopback reachability and cellular-bound relay readiness before macOS code exists.

- [x] **Step 1: Write a pairing-probe test against an in-process fake Android endpoint**

The test must prove P-256/HKDF/SAS parity, both confirmation proofs, 60-second expiry, and that the resulting secret is held in a `bytearray` which is overwritten on exit.

Run:

```bash
python3 -m unittest tools.tests.test_pairing_probe -v
```

Expected: failure before `pairing_probe.py` exists.

- [x] **Step 2: Implement the probe and scripts**

`tools/requirements-dev.txt` contains exactly `cryptography==46.0.1`. `pairing_probe.py` imports it explicitly and exits with installation guidance rather than silently changing protocol behavior when the package is missing. The script prints its SAS, waits for the operator to confirm it matches the Android screen, and writes the secret only to a mode-0600 temporary file created with `tempfile.mkstemp`; `smoke-android-relay.sh` overwrites that file before deleting it in an `EXIT INT TERM` trap.

`install-android-debug.sh` verifies exactly one authorized device, runs `./gradlew installDebug`, and opens `MainActivity`. `smoke-android-relay.sh` creates both forwards:

```bash
adb forward tcp:27184 tcp:27184
adb forward tcp:27183 tcp:27183
```

It pairs, asks the user to press Start on Android, runs DBP health, performs a DBP `OPEN_TCP` handshake to `example.com:443` without application data, then removes both forwards.

- [x] **Step 3: Run all automated tests before using a device**

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install --disable-pip-version-check -r tools/requirements-dev.txt
make verify-foundation
cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug
cd ..
python -m unittest discover -s tools/tests -p 'test_*.py' -v
```

- [x] **Step 4: Run the real-device smoke procedure**

```bash
./scripts/install-android-debug.sh
./scripts/smoke-android-relay.sh
```

Expected operator-visible sequence:

```text
ADB device: authorized
Pairing SAS: 6 digits and identical on both screens
Relay health: cellular=available protocol=DBP/1
OPEN_TCP example.com:443: OPEN_OK
```

With Android Wi-Fi enabled, inspect the app state and `dumpsys connectivity` to confirm the selected relay network has `TRANSPORT_CELLULAR`. This test does not claim that exact CGNAT addresses match.

- [x] **Step 5: Commit**

```bash
git add tools scripts docs/android-debug-smoke.md Makefile
git commit -m "test(android): add real device relay smoke gate"
```

## Android relay completion gate

Run:

```bash
make verify-foundation
cd android && ./gradlew testDebugUnitTest lintDebug assembleDebug
cd ..
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
./scripts/smoke-android-relay.sh
git status --short
```

The gate passes only when the device smoke reports DBP health and `OPEN_OK`, the Android screen reports a cellular network, and `git status --short` is empty. A skipped cellular instrumentation test does not satisfy the actual-device smoke requirement.
