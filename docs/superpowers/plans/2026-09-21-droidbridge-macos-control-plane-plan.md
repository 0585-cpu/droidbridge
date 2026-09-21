# DroidBridge macOS Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apple Silicon macOS 14+에서 Android 기기를 탐지하고, ADB forwarding·P-256 pairing·Keychain 저장·relay health 확인을 수행하는 SwiftUI 메뉴바 호스트 앱을 완성한다.

**Architecture:** testable logic은 `macos/Shared` Swift package에 넣고 HostApp은 actor 기반 coordinator와 UI만 조합한다. `AdbClient`가 외부 process를 캡슐화하고, `PairingClient`와 `RelayControlClient`는 loopback TCP만 사용한다. Pairing Secret은 shared Keychain access group에 저장하고 App Group에는 secret reference와 비민감 runtime configuration만 원자적으로 기록한다.

**Tech Stack:** Swift 6, Swift Concurrency, SwiftUI, CryptoKit, Network.framework, Security.framework, XcodeGen 2.46.0, XCTest, macOS 14 deployment target

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`

## Global Constraints

- Host app bundle id는 `io.droidbridge.macos`, Packet Tunnel extension id는 `io.droidbridge.macos.PacketTunnel`이다.
- App Group은 `group.io.droidbridge.shared`, Keychain access group entitlement는 `$(AppIdentifierPrefix)io.droidbridge.shared`다.
- Xcode project는 `project.yml`과 XcodeGen 2.46.0으로 생성하고 `.xcodeproj`는 commit하지 않는다.
- B1은 한 대의 paired Mac/Android 관계만 사용하고 Android에서 재페어링하면 기존 secret을 무효화한다.
- ADB executable 탐색 순서는 `ANDROID_HOME/platform-tools/adb`, `ANDROID_SDK_ROOT/platform-tools/adb`, `/opt/homebrew/bin/adb`, `/usr/local/bin/adb`, `PATH`다.
- pairing host port는 27184, relay host port는 27183으로 고정하고 둘 다 Android 동일 port로 forward한다.
- Pairing Secret은 command-line argument, environment variable, UserDefaults, App Group JSON, log에 기록하지 않는다.
- Host app이 종료되거나 사용자가 Disconnect하면 자신이 만든 ADB forwards만 제거한다.
- 여러 Android 기기가 있으면 자동 선택하지 않고 사용자 선택을 요구한다.
- 이 계획에서는 full Packet Tunnel을 시작하지 않는다. 완료 기준은 paired relay health가 cellular available을 반환하는 것이다.

## Review Focus

- `adb devices -l`의 unauthorized/offline/duplicate/공백·추가 필드 입력을 오판하지 않아야 한다.
- pairing 승인 전 앱 종료, USB 분리, 60초 timeout이 발생하면 임시 key와 secret이 저장되지 않아야 한다.
- Keychain item은 HostApp과 PacketTunnel extension만 접근 가능하고 App Group 파일에는 secret이 없어야 한다.
- 다른 process가 이미 사용 중인 27183/27184와 충돌할 때 무작정 제거하지 말고 명시적 오류를 표시해야 한다.
- ADB process가 hang하거나 stderr에 오류만 쓰는 경우 timeout 후 child process를 종료하고 UI 상태를 복구해야 한다.

---

### Task 1: XcodeGen project and shared Swift package foundation

**Files:**
- Create: `project.yml`
- Create: `macos/Shared/Package.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/DroidBridgeError.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/TunnelRuntimeConfiguration.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/TunnelRuntimeConfigurationTests.swift`
- Create: `macos/HostApp/App/DroidBridgeApp.swift`
- Create: `macos/HostApp/Resources/Info.plist`
- Create: `macos/HostApp/Resources/HostApp.entitlements`
- Create: `macos/PacketTunnel/PacketTunnelProvider.swift`
- Create: `macos/PacketTunnel/Resources/Info.plist`
- Create: `macos/PacketTunnel/Resources/PacketTunnel.entitlements`
- Create: `scripts/bootstrap-macos.sh`

**Interfaces:**
- Consumes: fixed bundle ids, App Group and runtime configuration from roadmap.
- Produces: local package `DroidBridgeShared`; generated `DroidBridge.xcodeproj`; buildable HostApp and an intentionally unavailable data-plane extension.

- [x] **Step 1: Write the failing runtime configuration round-trip test**

```swift
import XCTest
@testable import DroidBridgeShared

final class TunnelRuntimeConfigurationTests: XCTestCase {
    func testJSONRoundTripDoesNotContainSecretMaterial() throws {
        let configuration = TunnelRuntimeConfiguration(
            deviceSerial: "R58M123456A",
            relayHost: "127.0.0.1",
            relayPort: 27183,
            pairedPeerId: "peer-1",
            keychainAccount: "peer-1",
            maximumFlows: 128
        )
        let data = try JSONEncoder.droidBridge.encode(configuration)
        XCTAssertEqual(configuration, try JSONDecoder().decode(TunnelRuntimeConfiguration.self, from: data))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).localizedCaseInsensitiveContains("secret"))
    }
}
```

Also test relay host must be loopback, port must be 27183, and maximumFlows must be 1...256.

- [x] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared
```

Expected: failure because package and types do not exist.

- [x] **Step 3: Create exact project targets and minimal implementations**

`Package.swift` declares macOS 14, Swift language mode 6, one library target and one test target. `project.yml` defines:

```yaml
name: DroidBridge
options:
  deploymentTarget:
    macOS: "14.0"
packages:
  DroidBridgeShared:
    path: macos/Shared
targets:
  DroidBridgeHost:
    type: application
    platform: macOS
    sources: [macos/HostApp]
    dependencies:
      - package: DroidBridgeShared
      - target: DroidBridgePacketTunnel
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.droidbridge.macos
        CODE_SIGN_ENTITLEMENTS: macos/HostApp/Resources/HostApp.entitlements
  DroidBridgePacketTunnel:
    type: app-extension
    platform: macOS
    sources: [macos/PacketTunnel]
    dependencies:
      - package: DroidBridgeShared
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: io.droidbridge.macos.PacketTunnel
        CODE_SIGN_ENTITLEMENTS: macos/PacketTunnel/Resources/PacketTunnel.entitlements
```

The initial provider returns a typed error instead of silently starting:

```swift
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(
        options: [String : NSObject]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        completionHandler(DroidBridgeError.dataPlaneNotInstalled)
    }
}
```

`bootstrap-macos.sh` verifies XcodeGen 2.46.0, runs `xcodegen generate`, then `swift test --package-path macos/Shared`.

- [x] **Step 4: Run package tests and unsigned build**

```bash
./scripts/bootstrap-macos.sh
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: Swift package tests and unsigned compilation pass. Actual Packet Tunnel execution is not part of this task.

- [x] **Step 5: Commit**

```bash
git add project.yml macos scripts/bootstrap-macos.sh
git commit -m "build(macos): scaffold host and packet tunnel targets"
```

### Task 2: ADB executable discovery, process isolation, and device parsing

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Process/ProcessRunning.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Process/FoundationProcessRunner.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/ADB/AdbExecutableLocator.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/ADB/AdbClient.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/ADB/AdbDevice.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/AdbClientTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/AdbExecutableLocatorTests.swift`

**Interfaces:**
- Consumes: environment/path candidates.
- Produces: `AdbClient.devices()`, `forward(serial:hostPort:devicePort:)`, `removeForward`, `startActivity`, `packagePath`; all commands have a 5-second default timeout.

- [x] **Step 1: Write failing parser and timeout tests**

```swift
func testParsesAuthorizedUnauthorizedAndOfflineDevices() async throws {
    let output = """
    List of devices attached
    R58M123 device product:gts model:Galaxy_Tab transport_id:1
    ABC999 unauthorized usb:1-2 transport_id:2
    emulator-5554 offline transport_id:3
    """
    let runner = StubProcessRunner(stdout: output)
    let devices = try await AdbClient(executable: URL(fileURLWithPath: "/adb"), runner: runner).devices()
    XCTAssertEqual(devices.map(\.state), [.authorized, .unauthorized, .offline])
    XCTAssertEqual(devices.first?.model, "Galaxy_Tab")
}

func testTimedOutProcessIsTerminated() async {
    let runner = HangingProcessRunner()
    await XCTAssertThrowsErrorAsync {
        try await AdbClient(executable: URL(fileURLWithPath: "/adb"), runner: runner)
            .devices(timeout: .milliseconds(20))
    }
    XCTAssertTrue(runner.wasTerminated)
}
```

Add tests for daemon startup noise, blank lines, duplicate serials, exit code nonzero with stderr, and multiple Homebrew/path candidates.

- [x] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter Adb
```

- [x] **Step 3: Implement safe process execution**

`ProcessRunning` must return `ProcessResult(exitCode, stdout, stderr)` and accept executable URL, argument array, environment allowlist, and `Duration`. Never invoke a shell and never concatenate serial numbers into command strings.

Use a task group race between process completion and `Task.sleep(for: timeout)`; on timeout call `terminate()`, wait 500 ms, then `interrupt()` if still running. Limit captured stdout and stderr to 1 MiB each.

`AdbClient.forward` first runs `adb -s SERIAL forward --list`, refuses a conflicting owner, then executes:

```text
adb -s SERIAL forward tcp:HOST_PORT tcp:DEVICE_PORT
```

It records only forwards created by the current `AdbClient` instance and removes only those entries.

- [x] **Step 4: Run all ADB tests**

```bash
swift test --package-path macos/Shared --filter Adb
```

Expected: parser, conflict and timeout tests pass.

- [x] **Step 5: Commit**

```bash
git add macos/Shared/Sources/DroidBridgeShared/Process macos/Shared/Sources/DroidBridgeShared/ADB macos/Shared/Tests
git commit -m "feat(macos): manage adb devices and forwards safely"
```

### Task 3: Shared Keychain secret store and atomic App Group configuration

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Security/PairingSecretStore.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Security/KeychainPairingSecretStore.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Configuration/RuntimeConfigurationStore.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/PairingSecretStoreTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/RuntimeConfigurationStoreTests.swift`
- Modify: `macos/HostApp/Resources/HostApp.entitlements`
- Modify: `macos/PacketTunnel/Resources/PacketTunnel.entitlements`

**Interfaces:**
- Consumes: a 32-byte Pairing Secret and non-secret `TunnelRuntimeConfiguration`.
- Produces: `PairingSecretStore.save/load/delete`, `RuntimeConfigurationStore.write/read/delete`; both HostApp and extension share the same access groups.

- [x] **Step 1: Write failing storage contract tests**

```swift
func testSecretStoreRejectsWrongLengthAndNeverReturnsString() throws {
    let store = InMemoryPairingSecretStore()
    XCTAssertThrowsError(try store.save(Data(repeating: 1, count: 31), peerId: "peer"))
    try store.save(Data(repeating: 2, count: 32), peerId: "peer")
    XCTAssertEqual(try store.load(peerId: "peer"), Data(repeating: 2, count: 32))
}

func testRuntimeWriteIsAtomicAndMode0600() throws {
    let directory = temporaryDirectory()
    let store = FileRuntimeConfigurationStore(directory: directory)
    try store.write(validConfiguration)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, 0o600)
    XCTAssertNil(directoryContents(directory).first { $0.pathExtension == "tmp" })
}
```

Also test corrupted JSON, missing App Group container, replace existing config, and secret-like keys absent from serialized JSON.

- [x] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'PairingSecretStore|RuntimeConfigurationStore'
```

- [x] **Step 3: Implement storage**

Keychain query uses `kSecClassGenericPassword`, service `io.droidbridge.pairing.v1`, account equal to peer id, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, and configured access group. Replace existing data with `SecItemUpdate`; map `errSecItemNotFound`, duplicate, entitlement and interaction errors to typed `DroidBridgeError` values.

Runtime config writes JSON to App Group file `tunnel-runtime.json` via a unique sibling temporary file, sets `0600`, `fsync`s the file, then uses `FileManager.replaceItemAt`. Do not place Data/secret fields in `TunnelRuntimeConfiguration`.

Entitlements include the same App Group and the literal keychain entry `$(AppIdentifierPrefix)io.droidbridge.shared` on HostApp and PacketTunnel. Only the extension receives `com.apple.developer.networking.networkextension = packet-tunnel-provider`.

- [x] **Step 4: Run tests and inspect entitlements**

```bash
swift test --package-path macos/Shared
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' macos/HostApp/Resources/HostApp.entitlements
/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' macos/PacketTunnel/Resources/PacketTunnel.entitlements
```

Expected: both print `group.io.droidbridge.shared`.

- [x] **Step 5: Commit**

```bash
git add macos/Shared macos/HostApp/Resources/HostApp.entitlements macos/PacketTunnel/Resources/PacketTunnel.entitlements
git commit -m "feat(macos): protect pairing secret and runtime config"
```

### Task 4: P-256 pairing client with SAS confirmation

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Pairing/PairingModels.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Pairing/PairingCanonicalJSON.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Pairing/PairingClient.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Pairing/PairingCrypto.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/PairingCryptoTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/PairingClientTests.swift`

**Interfaces:**
- Consumes: Android pairing endpoint on loopback 27184 and user approval closure.
- Produces: `PairingResult(peerId, displayName, secret)` only after both proofs and approvals; progress events include six-digit SAS.

- [x] **Step 1: Write cross-language fixture and cancellation tests**

Use the same deterministic private scalars/nonces as Android unit tests and assert identical public key X9.63 bytes, transcript hash, 32-byte secret, six-digit SAS and confirmation HMAC.

```swift
func testCancellationBeforeApprovalDoesNotPersist() async throws {
    let store = SpyPairingSecretStore()
    let client = PairingClient(connectionFactory: FakePairingConnection.awaitingApproval, store: store)
    let task = Task { try await client.pair(peerId: "mac-1", displayName: "MacBook") { _ in
        try await Task.never()
    }}
    task.cancel()
    await XCTAssertThrowsErrorAsync { _ = try await task.value }
    XCTAssertEqual(store.saveCount, 0)
}
```

Test frame length 0/8193, invalid JSON, wrong role, transcript tamper, peer rejection, endpoint EOF and 60-second timeout.

- [x] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter Pairing
```

- [x] **Step 3: Implement exact Android-compatible crypto and framing**

Use `P256.KeyAgreement.PrivateKey`, raw X9.63 public representation, SHA256 transcript, HKDF-SHA256 with 32-byte output and info `DroidBridge DBP/1 Pairing`. Canonical JSON uses sorted UTF-8 keys and no insignificant whitespace. Four-byte length prefix is unsigned big-endian and maximum 8192.

The client exposes:

```swift
public func pair(
    peerId: String,
    displayName: String,
    approveSAS: @Sendable (String) async throws -> Bool
) async throws -> PairingResult
```

Zero mutable secret buffers with `resetBytes(in:)` on every failure/cancellation path. Persist through `PairingSecretStore` only after Android confirmation proof verifies.

- [x] **Step 4: Run tests including Python fixture parity**

```bash
swift test --package-path macos/Shared --filter Pairing
python3 -m unittest tools.tests.test_pairing_probe -v
```

Expected: Swift and Python derive the same committed fixture values.

- [x] **Step 5: Commit**

```bash
git add macos/Shared/Sources/DroidBridgeShared/Pairing macos/Shared/Tests
git commit -m "feat(macos): pair with android using p256 sas"
```

### Task 5: Authenticated relay health client and ADB relay preparation

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Protocol/DbpCodec.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Protocol/SessionAuthenticator.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayControlClient.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayHealth.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Relay/RelayPreparer.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/DbpCodecTests.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/RelayControlClientTests.swift`

**Interfaces:**
- Consumes: shared DBP fixtures, ADB client, Pairing Secret.
- Produces: `RelayPreparer.prepare(device, secret) -> RelayPreparation`; authenticated `health()` response.

- [x] **Step 1: Write fixture and preparation rollback tests**

```swift
func testPrepareRollsBackPairingForwardWhenRelayForwardFails() async {
    let adb = StubAdbClient(results: [.success, .failure(.portInUse)])
    let preparer = RelayPreparer(adb: adb, healthClient: StubHealthClient())
    await XCTAssertThrowsErrorAsync {
        _ = try await preparer.prepare(device: authorizedDevice, secret: validSecret)
    }
    XCTAssertEqual(adb.removedForwards, [27184])
}
```

Add byte-for-byte DBP vector tests, wrong HELLO_OK nonce, HMAC mismatch, health timeout, cellular unavailable response and app-not-running response.

- [x] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter 'Dbp|Relay'
```

- [x] **Step 3: Implement DBP health protocol**

Health response payload is fixed as:

```text
1 byte   status: 0=ready, 1=cellular unavailable, 2=stopping
2 bytes  active sessions
2 bytes  maximum sessions
8 bytes  uploaded bytes
8 bytes  downloaded bytes
1 byte   carrier display-name length, 0...63
N bytes  UTF-8 carrier display name
```

`RelayControlClient.health()` opens `NWConnection` to `127.0.0.1:27183`, performs HELLO/HELLO_OK, sends HEALTH with the negotiated nonce pair, validates response HMAC and all payload bounds, then closes. Total timeout is 3 seconds.

`RelayPreparer` verifies package `io.droidbridge.android`, creates pairing and relay forwards, asks ADB to open the Android activity if relay health is unavailable, and rolls back only forwards it created on failure.

- [x] **Step 4: Run tests**

```bash
cp protocol/test-vectors/dbp-v1.json macos/Shared/Tests/DroidBridgeSharedTests/Fixtures-dbp-v1.json
swift test --package-path macos/Shared --filter 'Dbp|Relay'
```

Expected: all vector and rollback tests pass.

- [x] **Step 5: Commit**

```bash
git add macos/Shared/Sources/DroidBridgeShared/Protocol macos/Shared/Sources/DroidBridgeShared/Relay macos/Shared/Tests
git commit -m "feat(macos): prepare and authenticate android relay"
```

### Task 6: Actor coordinator and SwiftUI menu bar application

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Host/HostAppState.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Host/DroidBridgeCoordinatorCore.swift`
- Create: `macos/HostApp/App/DroidBridgeCoordinatorAdapter.swift`
- Create: `macos/HostApp/UI/MenuBarContentView.swift`
- Create: `macos/HostApp/UI/DevicePickerView.swift`
- Create: `macos/HostApp/UI/PairingApprovalView.swift`
- Create: `macos/HostApp/Device/DeviceMonitor.swift`
- Create: `macos/Shared/Tests/DroidBridgeSharedTests/HostStateMachineTests.swift`
- Modify: `macos/HostApp/App/DroidBridgeApp.swift`

**Interfaces:**
- Consumes: ADB, pairing, Keychain, relay preparer, runtime config store.
- Produces: testable `DroidBridgeCoordinatorCore` actor in the shared package, a `@MainActor` HostApp adapter, and user actions `refresh`, `selectDevice`, `pair`, `prepareRelay`, `disconnect`.

- [x] **Step 1: Write failing state-machine tests**

```swift
func testUSBRemovalFromRelayReadyClearsForwardsButKeepsPairing() async {
    let harness = HostCoordinatorHarness(initial: .relayReady(health: readyHealth))
    await harness.coordinator.deviceSnapshotChanged([])
    XCTAssertEqual(await harness.coordinator.state, .deviceMissing)
    XCTAssertEqual(harness.adb.removedPorts.sorted(), [27183, 27184])
    XCTAssertEqual(harness.secretStore.deleteCount, 0)
}

func testMultipleDevicesRequiresSelection() async {
    let harness = HostCoordinatorHarness(initial: .idle)
    await harness.coordinator.deviceSnapshotChanged([deviceA, deviceB])
    XCTAssertEqual(await harness.coordinator.state, .deviceSelectionRequired([deviceA, deviceB]))
    XCTAssertNil(harness.selectedSerial)
}
```

Also test unauthorized guidance, pairing cancellation, health cellular unavailable, explicit Forget deletes secret, and Disconnect does not delete secret.

- [x] **Step 2: Run and verify failure**

```bash
swift test --package-path macos/Shared --filter HostStateMachine
```

- [x] **Step 3: Implement coordinator and UI**

`DroidBridgeCoordinatorCore` is an `actor` in `DroidBridgeShared`; all long-running operations have one owned `Task` cancelled before a new operation. `DroidBridgeCoordinatorAdapter` is `@MainActor`, observes the core through an `AsyncStream<HostAppState>`, and publishes immutable state to SwiftUI. This placement makes the state machine directly testable by the Swift package without importing the application target.

Use `MenuBarExtra("DroidBridge", systemImage: "cable.connector")`. UI must show:

- ADB missing / unauthorized / offline guidance
- authorized device picker when count > 1
- Pair New Mac or Forget Mac
- SAS with Approve/Reject
- Prepare Relay / Disconnect
- cellular state, carrier name, active flows, byte totals, last safe error

No button starts the Packet Tunnel in this plan. The status text explicitly says `Relay ready; full tunnel not installed` after health succeeds.

- [x] **Step 4: Build and run unit tests**

```bash
./scripts/bootstrap-macos.sh
swift test --package-path macos/Shared
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: all tests pass and menu bar app compiles.

- [x] **Step 5: Commit**

```bash
git add macos/HostApp macos/Shared/Sources/DroidBridgeShared/Host macos/Shared/Tests
git commit -m "feat(macos): add relay preparation menu bar workflow"
```

### Task 7: Signed real-device control-plane smoke gate

**Files:**
- Create: `scripts/run-macos-control-smoke.sh`
- Create: `docs/macos-control-smoke.md`
- Modify: `README.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: signed HostApp, actual Android relay, approved ADB device.
- Produces: verified path from device detection through pairing and authenticated cellular health.

- [x] **Step 1: Add non-device preflight tests**

`run-macos-control-smoke.sh --preflight` checks `uname -m == arm64`, macOS major >= 14, XcodeGen 2.46.0, valid signing team variable `DROIDBRIDGE_DEVELOPMENT_TEAM`, one authorized ADB device, and installed Android package. Each failure prints one remediation command and exits nonzero.

Run:

```bash
./scripts/run-macos-control-smoke.sh --preflight
```

Expected: fails clearly until signing team and a device are available; it must never modify forwards during preflight.

- [x] **Step 2: Implement signed build and launch path**

The script runs:

```bash
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost \
  -configuration Debug \
  DEVELOPMENT_TEAM="$DROIDBRIDGE_DEVELOPMENT_TEAM" \
  -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/DroidBridgeHost.app
```

It does not automate SAS approval. The document instructs the operator to pair, press Start on Android, select Prepare Relay, and capture only safe state screenshots with no secret material.

- [x] **Step 3: Execute the real-device smoke**

```bash
./scripts/run-macos-control-smoke.sh
```

Expected UI state:

```text
Device: authorized
Pairing: approved
Relay: ready
Cellular: available
Full tunnel: not installed
```

Then unplug USB. Within the next poll interval, UI becomes `Device missing`, both forwards are removed, and pairing remains available after reconnect.

- [x] **Step 4: Run the complete control-plane gate**

```bash
swift test --package-path macos/Shared
cd android && ./gradlew testDebugUnitTest assembleDebug && cd ..
./scripts/run-macos-control-smoke.sh
git status --short
```

Expected: all tests and real-device health pass; working tree is clean.

- [x] **Step 5: Commit**

```bash
git add scripts/run-macos-control-smoke.sh docs/macos-control-smoke.md README.md Makefile
git commit -m "test(macos): verify paired relay control plane on device"
```

## macOS control-plane completion gate

The plan is complete only when the signed HostApp can pair with the Android app, store a 32-byte secret in shared Keychain, prepare both ADB forwards, and display an authenticated `cellular=available` health result. A successful Python probe alone does not satisfy this gate.
