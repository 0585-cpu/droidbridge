# DroidBridge utun Helper App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the macOS NE-extension host with a root `utun` LaunchDaemon driven by the menu-bar app, so DroidBridge runs a fail-closed full-tunnel cellular exit signable with a free Apple Development certificate.

**Architecture:** A menu-bar app (user context) installs and drives a root helper over XPC. The helper opens a `utun` interface, runs the existing C packet engine + relay stack, changes the default route, and enforces a pf-based kill-switch. The DBP protocol, pairing, relay, C engine, and Android app are reused unchanged; only the packet source/sink and the privilege/kill-switch layer are new.

**Tech Stack:** Swift 6 (SwiftPM + Xcode targets), C (existing lwIP engine), macOS `utun` (`PF_SYSTEM`/`SYSPROTO_CONTROL`), `pf` (pfctl anchors), `route`, XPC (`NSXPCListener`), `SMAppService`/`AuthorizationServices`, XcodeGen, assert-based `Checks` harness (CLT has no XCTest).

**Spec:** `docs/superpowers/specs/2026-09-22-droidbridge-utun-helper-app-design.md`

## Global Constraints

- Apple Silicon, macOS 14+. Sign with the free Apple Development cert; **no SIP/AMFI changes**.
- Team ID `ABCDE12345` is injected at build time (`DEVELOPMENT_TEAM=`), **never committed** to `project.yml`.
- The SwiftPM `macos/Shared` package must stay **CLT-buildable**: it may NOT import `DroidBridgeCore` (the C module) or `NetworkExtension`. C/utun-dependent code lives in Xcode-only groups.
- Tests run via the assert-based `Checks` executable (`make check-macos`), not XCTest. C core via `make test-core`.
- Relay reaches the phone at `127.0.0.1:27183` (adb forward, loopback + USB). B1 is IPv4-only; drop IPv6 frames.
- utun MTU stays 1280 (engine parity). Fail-closed ordering is invariant: **load pf → set route** on start; **restore route → unload pf** on stop.
- Keep the NE extension target (`macos/PacketTunnel`) building unsigned throughout (dormant, revived on a paid account).

## File Structure

- `macos/Shared/Sources/DroidBridgeShared/Tunnel/PacketSource.swift` — `PacketSource` + `PacketIngesting` protocols (pure).
- `macos/Shared/Sources/DroidBridgeShared/Tunnel/UtunFraming.swift` — 4-byte AF header codec (pure).
- `macos/Shared/Sources/DroidBridgeShared/Tunnel/PfRuleBuilder.swift` — pf anchor body generator (pure).
- `macos/Shared/Sources/DroidBridgeShared/Tunnel/RouteCommandBuilder.swift` — `route` argv generator (pure).
- `macos/Shared/Sources/DroidBridgeShared/XPC/DroidBridgeHelperProtocol.swift` — XPC contract + code-requirement string builder (pure).
- `macos/Shared/Sources/Checks/UtunFramingChecks.swift`, `PfRouteChecks.swift`, `XpcContractChecks.swift`, `PacketSourceChecks.swift` — CLT tests.
- `macos/CoreHost/` (new Xcode group, compiled into BOTH PacketTunnel and Helper): moved `EngineBridge.swift`, `CoreCallbacks.swift`, `NWDbpConnection.swift`, and the refactored transport-agnostic `TunnelController.swift`.
- `macos/PacketTunnel/Tunnel/NEPacketFlowSource.swift` — thin NE adapter (stays in the NE target).
- `macos/Helper/` — `main.swift`, `UtunDevice.swift`, `UtunPacketSource.swift`, `RouteController.swift`, `PfController.swift`, `HelperService.swift`, `Info.plist`, `io.droidbridge.helper.plist`, `Helper.entitlements`.
- `macos/HostApp/Helper/HelperClient.swift` — app-side XPC client + install (SMAppService → manual).
- `project.yml`, `scripts/build-signed-macos.sh`, `scripts/b1-preflight.sh` — target + build + preflight updates.

---

### Task 1: Feasibility spike — signed helper registration + utun open

Decide whether a free-cert-signed app can register/launch a root helper via `SMAppService`, or whether we fall back to a manual authorized install. Produce a throwaway skeleton that proves helper launch + `utun` open, then record the decision.

**Files:**
- Create (throwaway, kept minimal): `macos/Helper/main.swift`, `macos/Helper/io.droidbridge.helper.plist`, `macos/Helper/Info.plist`, `macos/Helper/Helper.entitlements`
- Modify: `project.yml` (add temporary `DroidBridgeHelper` executable target, embedded in the app)
- Create: `docs/spike-smappservice.md` (decision record)

**Interfaces:**
- Produces: the registration decision consumed by Task 7 (`useSMAppService: Bool`) and the helper plist label `io.droidbridge.helper`.

- [ ] **Step 1: Minimal helper that opens utun and logs**

```swift
// macos/Helper/main.swift (spike form)
import Foundation
import Darwin

func openUtun() -> Int32 {
    let fd = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
    guard fd >= 0 else { return -1 }
    var info = ctl_info()
    withUnsafeMutablePointer(to: &info.ctl_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.ctl_name)) {
            _ = strcpy($0, "com.apple.net.utun_control")
        }
    }
    guard ioctl(fd, CTLIOCGINFO, &info) >= 0 else { close(fd); return -1 }
    var addr = sockaddr_ctl(sc_len: UInt8(MemoryLayout<sockaddr_ctl>.size), sc_family: UInt8(AF_SYSTEM),
                            ss_sysaddr: UInt16(AF_SYS_CONTROL), sc_id: info.ctl_id, sc_unit: 0,
                            sc_reserved: (0,0,0,0,0))
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size)) }
    }
    guard rc >= 0 else { close(fd); return -1 }
    return fd
}

NSLog("DroidBridgeHelper spike starting as uid=\(getuid())")
let fd = openUtun()
NSLog("utun open fd=\(fd) (>=0 means an interface was created)")
RunLoop.main.run()
```

- [ ] **Step 2: Build signed and register via SMAppService**

Add a temporary `DroidBridgeHelper` target to `project.yml` embedded under the app's `Contents/Library/LaunchDaemons`/`Contents/MacOS`, then from a scratch app call:

```swift
try SMAppService.daemon(plistName: "io.droidbridge.helper.plist").register()
```

Build: `DROIDBRIDGE_DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-signed-macos.sh` (extend it in Task 8; for the spike, invoke `xcodebuild … -allowProvisioningUpdates DEVELOPMENT_TEAM=ABCDE12345` directly).

- [ ] **Step 3: Observe result and decide**

Run the app, approve in System Settings if prompted, then check:

```bash
sudo launchctl print system/io.droidbridge.helper 2>&1 | head
log show --last 2m --predicate 'process == "DroidBridgeHelper"' | grep utun
```

Expected outcomes:
- SMAppService registers and the helper logs `utun open fd>=0` → **decision: SMAppService**.
- `register()` throws (e.g. `Operation not permitted`, code-sign/notarization rejection) → **decision: manual install** (Task 7 uses `AuthorizationServices` + `launchctl bootstrap`).

- [ ] **Step 4: Record the decision**

Write `docs/spike-smappservice.md` with: which path worked, the exact error if SMAppService failed, and the approval UX observed. Update memory `droidbridge-workspace.md` with the decision.

- [ ] **Step 5: Commit**

```bash
git add macos/Helper project.yml docs/spike-smappservice.md
git commit -m "spike: prove root helper launch + utun open on free cert"
```

---

### Task 2: Pure Shared building blocks (framing, pf, route, XPC contract)

All CLT-testable, no C/root/NE. This front-loads everything testable so the risky root code (Tasks 5-6) is thin.

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Tunnel/UtunFraming.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Tunnel/PfRuleBuilder.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/Tunnel/RouteCommandBuilder.swift`
- Create: `macos/Shared/Sources/DroidBridgeShared/XPC/DroidBridgeHelperProtocol.swift`
- Create: `macos/Shared/Sources/Checks/UtunFramingChecks.swift`, `PfRouteChecks.swift`, `XpcContractChecks.swift`
- Modify: `macos/Shared/Sources/Checks/main.swift` (register new check groups)

**Interfaces:**
- Produces:
  - `enum UtunFraming { static func encode(_ ipv4: Data) -> Data; static func decode(_ frame: Data) -> Data? }`
  - `struct PfRuleBuilder { let utun: String; let physical: [String]; func anchorBody() -> String }`
  - `struct RouteCommandBuilder { let utun: String; func setDefault() -> [[String]]; func restoreDefault(gateway: String) -> [[String]] }`
  - `@objc protocol DroidBridgeHelperProtocol` (see Step 5) and `enum HelperCodeRequirement { static func string(teamID: String, bundleID: String) -> String }`

- [ ] **Step 1: Failing test — utun framing**

```swift
// UtunFramingChecks.swift
import Foundation
import DroidBridgeShared

func runUtunFramingChecks() -> (String, Int, Int) {
    var passed = 0, failed = 0
    func check(_ c: Bool, _ m: String) { if c { passed += 1 } else { failed += 1; print("FAIL utun: \(m)") } }

    let ipv4 = Data([0x45, 0x00, 0x00, 0x14, 0, 0, 0, 0, 0x40, 0x06, 0, 0, 10,0,0,1, 93,184,216,34])
    let framed = UtunFraming.encode(ipv4)
    check(framed.count == ipv4.count + 4, "encode adds 4-byte header")
    check(Array(framed.prefix(4)) == [0,0,0,2], "AF_INET big-endian header")   // AF_INET = 2
    check(UtunFraming.decode(framed) == ipv4, "decode round-trips")
    check(UtunFraming.decode(Data([0,0,0,30]) + ipv4) == nil, "rejects AF_INET6 (30)")
    check(UtunFraming.decode(Data([0,0,0,2,0x45])) != nil, "accepts minimal AF_INET frame")
    check(UtunFraming.decode(Data([0,0,2])) == nil, "rejects short frame")
    return ("utunFraming", passed, failed)
}
```

- [ ] **Step 2: Run — verify fail**

Run: `make check-macos`
Expected: FAIL — `UtunFraming` unresolved.

- [ ] **Step 3: Implement UtunFraming**

```swift
// UtunFraming.swift
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// macOS utun frames carry a 4-byte address-family header in network byte order.
public enum UtunFraming {
    private static let afInet = UInt32(AF_INET)  // 2

    public static func encode(_ ipv4: Data) -> Data {
        var be = afInet.bigEndian
        var out = Data(bytes: &be, count: 4)
        out.append(ipv4)
        return out
    }

    public static func decode(_ frame: Data) -> Data? {
        guard frame.count > 4 else { return nil }
        let af = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard af == afInet else { return nil }
        return frame.subdata(in: 4 ..< frame.count)
    }
}
```

- [ ] **Step 4: Failing test — pf + route builders**

```swift
// PfRouteChecks.swift
import DroidBridgeShared

func runPfRouteChecks() -> (String, Int, Int) {
    var passed = 0, failed = 0
    func check(_ c: Bool, _ m: String) { if c { passed += 1 } else { failed += 1; print("FAIL pf/route: \(m)") } }

    let pf = PfRuleBuilder(utun: "utun4", physical: ["en0", "en1"]).anchorBody()
    check(pf.contains("pass quick on lo0"), "loopback (relay) allowed")
    check(pf.contains("pass quick on utun4"), "tunnel allowed")
    check(pf.contains("block drop out quick on en0 all"), "en0 egress blocked")
    check(pf.contains("block drop out quick on en1 all"), "en1 egress blocked")
    check(!pf.contains("pass") || pf.range(of: "pass quick on en") == nil, "no physical pass-through")

    let r = RouteCommandBuilder(utun: "utun4")
    check(r.setDefault().contains(["route", "-n", "add", "-inet", "default", "-interface", "utun4"]), "set default via utun")
    check(r.restoreDefault(gateway: "192.168.0.1").contains(["route", "-n", "add", "-inet", "default", "192.168.0.1"]), "restore original gateway")
    return ("pfRoute", passed, failed)
}
```

- [ ] **Step 5: Run — verify fail, then implement pf/route + XPC contract**

Run `make check-macos` (expect FAIL: builders unresolved), then:

```swift
// PfRuleBuilder.swift
import Foundation
/// Generates the body of the `io.droidbridge` pf anchor. Kill-switch: only loopback (relay)
/// and the tunnel may egress; every physical interface is blocked outbound.
public struct PfRuleBuilder {
    public let utun: String
    public let physical: [String]
    public init(utun: String, physical: [String]) { self.utun = utun; self.physical = physical }
    public func anchorBody() -> String {
        var lines = ["set block-policy drop", "pass quick on lo0", "pass quick on \(utun)"]
        for i in physical { lines.append("block drop out quick on \(i) all") }
        return lines.joined(separator: "\n") + "\n"
    }
}
```

```swift
// RouteCommandBuilder.swift
import Foundation
/// Generates argv for `route` to move the default route onto utun and restore it.
public struct RouteCommandBuilder {
    public let utun: String
    public init(utun: String) { self.utun = utun }
    public func setDefault() -> [[String]] {
        [["route", "-n", "add", "-inet", "default", "-interface", utun]]
    }
    public func restoreDefault(gateway: String) -> [[String]] {
        [["route", "-n", "delete", "-inet", "default", "-interface", utun],
         ["route", "-n", "add", "-inet", "default", gateway]]
    }
}
```

```swift
// DroidBridgeHelperProtocol.swift
import Foundation
/// XPC contract between the app (user) and the root helper. Data payloads are JSON
/// (TunnelConfig / TunnelMetricsSnapshot) so no shared model classes cross the boundary.
@objc public protocol DroidBridgeHelperProtocol {
    func installStatus(reply: @escaping (Bool) -> Void)
    func startTunnel(configJSON: Data, secret: Data, reply: @escaping (Bool, String?) -> Void)
    func status(reply: @escaping (Data) -> Void)
    func stopTunnel(reply: @escaping (Bool) -> Void)
}

/// Designated-requirement string the helper enforces on every XPC peer and the app enforces
/// on the helper, so only our signed binaries talk to each other.
public enum HelperCodeRequirement {
    public static let machServiceName = "io.droidbridge.helper"
    public static func string(teamID: String, bundleID: String) -> String {
        "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    }
}
```

- [ ] **Step 6: Failing test — XPC requirement string**

```swift
// XpcContractChecks.swift
import DroidBridgeShared

func runXpcContractChecks() -> (String, Int, Int) {
    var passed = 0, failed = 0
    func check(_ c: Bool, _ m: String) { if c { passed += 1 } else { failed += 1; print("FAIL xpc: \(m)") } }
    let req = HelperCodeRequirement.string(teamID: "ABCDE12345", bundleID: "io.droidbridge.macos")
    check(req.contains("identifier \"io.droidbridge.macos\""), "pins bundle id")
    check(req.contains("certificate leaf[subject.OU] = \"ABCDE12345\""), "pins team OU")
    check(req.contains("anchor apple generic"), "requires Apple anchor")
    check(HelperCodeRequirement.machServiceName == "io.droidbridge.helper", "mach service name")
    return ("xpcContract", passed, failed)
}
```

- [ ] **Step 7: Register checks and run all**

Add to `macos/Shared/Sources/Checks/main.swift` the three new groups (`runUtunFramingChecks`, `runPfRouteChecks`, `runXpcContractChecks`) alongside the existing ones.

Run: `make check-macos`
Expected: all groups PASS (existing 108 + new).

- [ ] **Step 8: Commit**

```bash
git add macos/Shared/Sources/DroidBridgeShared/Tunnel macos/Shared/Sources/DroidBridgeShared/XPC macos/Shared/Sources/Checks
git commit -m "feat(macos): pure utun/pf/route/xpc building blocks with CLT checks"
```

---

### Task 3: Relocate engine host to CoreHost + PacketSource refactor

Move the C-engine-driven code out of the NE target into a shared Xcode group both PacketTunnel and Helper compile, and decouple it from `NEPacketTunnelFlow` via `PacketSource`.

**Files:**
- Create: `macos/Shared/Sources/DroidBridgeShared/Tunnel/PacketSource.swift`
- Move: `macos/PacketTunnel/Core/{EngineBridge,CoreCallbacks,NWDbpConnection}.swift` → `macos/CoreHost/`
- Move + modify: `macos/PacketTunnel/Tunnel/TunnelController.swift` → `macos/CoreHost/TunnelController.swift`
- Create: `macos/PacketTunnel/Tunnel/NEPacketFlowSource.swift`
- Modify: `macos/PacketTunnel/PacketTunnelProvider.swift` (construct `NEPacketFlowSource`)
- Modify: `project.yml` (add `macos/CoreHost` to PacketTunnel sources)
- Create: `macos/Shared/Sources/Checks/PacketSourceChecks.swift`

**Interfaces:**
- Consumes: `EngineBridge`, `RelayFlowConnection` (unchanged).
- Produces:
  - `public protocol PacketSource: AnyObject { func read(_ handler: @escaping ([Data]) -> Void); func write(_ packets: [Data]) }`
  - `public protocol PacketIngesting: AnyObject { func ingest(_ packet: Data) }` (EngineBridge conforms)
  - `TunnelController.init(packetSource: PacketSource, secret: Data, relayHost: String, relayPort: UInt16, engineFactory: (EngineBridgeDelegate) -> PacketIngesting)`

- [ ] **Step 1: Failing test — TunnelController pumps source → ingester**

```swift
// PacketSourceChecks.swift  (runs in Checks; uses fakes, no C engine)
import Foundation
import DroidBridgeShared

final class FakeSource: PacketSource {
    var queued: [[Data]]; var written: [Data] = []
    private var handler: (([Data]) -> Void)?
    init(_ batches: [[Data]]) { queued = batches }
    func read(_ handler: @escaping ([Data]) -> Void) {
        self.handler = handler
        if !queued.isEmpty { handler(queued.removeFirst()) }
    }
    func write(_ packets: [Data]) { written.append(contentsOf: packets) }
}

func runPacketSourceChecks() -> (String, Int, Int) {
    var passed = 0, failed = 0
    func check(_ c: Bool, _ m: String) { if c { passed += 1 } else { failed += 1; print("FAIL pktsrc: \(m)") } }
    // PacketSource contract only (TunnelController needs the C engine, exercised in Task 6 / device):
    let src = FakeSource([[Data([0x45, 0x00]), Data([0x45, 0x01])]])
    var got: [Data] = []
    src.read { got.append(contentsOf: $0) }
    check(got.count == 2, "read delivers a batch")
    src.write([Data([0xAA])])
    check(src.written == [Data([0xAA])], "write records packets")
    return ("packetSource", passed, failed)
}
```

- [ ] **Step 2: Run — verify fail**

Run: `make check-macos`
Expected: FAIL — `PacketSource` unresolved.

- [ ] **Step 3: Add PacketSource + PacketIngesting, register check**

```swift
// PacketSource.swift  (Shared, pure)
import Foundation
public protocol PacketSource: AnyObject {
    /// Perform one read; invoke `handler` once with a batch of raw IPv4 packets.
    func read(_ handler: @escaping ([Data]) -> Void)
    func write(_ packets: [Data])
}
public protocol PacketIngesting: AnyObject {
    func ingest(_ packet: Data)
}
```

Register `runPacketSourceChecks` in `Checks/main.swift`. Run `make check-macos` → PASS.

- [ ] **Step 4: Move engine-host files into `macos/CoreHost/` (git mv), no code change yet**

```bash
mkdir -p macos/CoreHost
git mv macos/PacketTunnel/Core/EngineBridge.swift macos/CoreHost/EngineBridge.swift
git mv macos/PacketTunnel/Core/CoreCallbacks.swift macos/CoreHost/CoreCallbacks.swift
git mv macos/PacketTunnel/Core/NWDbpConnection.swift macos/CoreHost/NWDbpConnection.swift
git mv macos/PacketTunnel/Tunnel/TunnelController.swift macos/CoreHost/TunnelController.swift
```

- [ ] **Step 5: Make EngineBridge conform to PacketIngesting; refactor TunnelController to PacketSource**

In `EngineBridge.swift` add `import DroidBridgeShared` and `extension EngineBridge: PacketIngesting {}` (it already has `func ingest(_:)`).

Rewrite `TunnelController` to depend on `PacketSource` instead of `NEPacketTunnelFlow`:

```swift
// macos/CoreHost/TunnelController.swift  (key changes)
import DroidBridgeCore
import Foundation
import DroidBridgeShared

final class TunnelController: NSObject, EngineBridgeDelegate, RelayFlowDelegate, @unchecked Sendable {
    private let source: PacketSource
    private let secret: Data
    private let relayHost: String
    private let relayPort: UInt16
    private let engineFactory: (EngineBridgeDelegate) -> PacketIngesting
    private var engine: PacketIngesting?
    private let flowsLock = NSLock()
    private var flows: [UInt32: RelayFlowConnection] = [:]
    private let dnsClient: RelayDNSClient

    init(packetSource: PacketSource, secret: Data, relayHost: String = "127.0.0.1", relayPort: UInt16 = 27183,
         engineFactory: @escaping (EngineBridgeDelegate) -> PacketIngesting = { EngineBridge(delegate: $0) }) {
        self.source = packetSource; self.secret = secret
        self.relayHost = relayHost; self.relayPort = relayPort; self.engineFactory = engineFactory
        let host = relayHost, port = relayPort
        self.dnsClient = RelayDNSClient(secret: secret, transportFactory: { NWConnectionTransport(host: host, port: port) })
        super.init()
    }
    func start() { engine = engineFactory(self); readLoop() }
    private func readLoop() {
        source.read { [weak self] packets in
            guard let self else { return }
            self.readLoop()
            for p in packets { self.engine?.ingest(p) }
        }
    }
    func engineEmitPacket(_ data: Data) { source.write([data]) }
    // engineOpenFlow / engineSendFlow / engineCloseFlow / engineSendDNS / relayFlow* : unchanged from the pre-move file.
}
```

(The delegate methods and `stop()` keep their existing bodies; only the packet source/sink and `engine` type changed. `engine` is now `PacketIngesting`; the delegate callbacks that call `engine?.relayOpened(...)` etc. need `engine as? EngineBridge` — instead keep a concrete `private var engineBridge: EngineBridge?` set inside `start()` when the factory returns one, and route relay callbacks through it. Simplest: keep both `engine: PacketIngesting?` for ingest and cast once in `start()`.)

- [ ] **Step 6: Add NEPacketFlowSource adapter in the NE target**

```swift
// macos/PacketTunnel/Tunnel/NEPacketFlowSource.swift
import NetworkExtension
import DroidBridgeShared

final class NEPacketFlowSource: PacketSource {
    private let flow: NEPacketTunnelFlow
    init(_ flow: NEPacketTunnelFlow) { self.flow = flow }
    func read(_ handler: @escaping ([Data]) -> Void) {
        flow.readPackets { packets, protocols in
            handler(zip(packets, protocols).filter { $0.1.int32Value == AF_INET }.map { $0.0 })
        }
    }
    func write(_ packets: [Data]) {
        flow.writePackets(packets, withProtocols: packets.map { _ in NSNumber(value: AF_INET) })
    }
}
```

In `PacketTunnelProvider.swift`, change `TunnelController(packetFlow: self.packetFlow, …)` to `TunnelController(packetSource: NEPacketFlowSource(self.packetFlow), …)`.

- [ ] **Step 7: Update project.yml + build unsigned + checks**

Add `macos/CoreHost` to the `DroidBridgePacketTunnel` sources list in `project.yml`. Then:

```bash
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost -configuration Debug CODE_SIGNING_ALLOWED=NO build
make check-macos
```

Expected: `** BUILD SUCCEEDED **` and all checks PASS (108 + new).

- [ ] **Step 8: Commit**

```bash
git add macos/CoreHost macos/PacketTunnel macos/Shared project.yml
git commit -m "refactor(macos): extract PacketSource, relocate engine host to CoreHost"
```

---

### Task 4: XPC service skeleton with peer validation

**Files:**
- Create: `macos/Helper/HelperService.swift`
- Modify: `macos/Helper/main.swift` (host an `NSXPCListener`)
- Modify: `project.yml` (Helper links DroidBridgeShared; add `macos/CoreHost`)

**Interfaces:**
- Consumes: `DroidBridgeHelperProtocol`, `HelperCodeRequirement` (Task 2).
- Produces: `final class HelperService: NSObject, NSXPCListenerDelegate, DroidBridgeHelperProtocol` with `func validate(_ connection: NSXPCConnection) -> Bool`.

- [ ] **Step 1: Implement peer validation using the audit token**

```swift
// macos/Helper/HelperService.swift
import Foundation
import DroidBridgeShared

final class HelperService: NSObject, NSXPCListenerDelegate, DroidBridgeHelperProtocol {
    private let requirement: String
    init(teamID: String = "ABCDE12345", bundleID: String = "io.droidbridge.macos") {
        self.requirement = HelperCodeRequirement.string(teamID: teamID, bundleID: bundleID)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard validate(c) else { return false }
        c.exportedInterface = NSXPCInterface(with: DroidBridgeHelperProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }

    func validate(_ connection: NSXPCConnection) -> Bool {
        var token = connection.value(forKey: "auditToken")  // audit_token_t via KVC
        guard var auditToken = token as? Data else { return false }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else { return false }
        return SecCodeCheckValidity(code, [], req) == errSecSuccess
    }

    // Contract methods — real bodies land in Task 6.
    func installStatus(reply: @escaping (Bool) -> Void) { reply(true) }
    func startTunnel(configJSON: Data, secret: Data, reply: @escaping (Bool, String?) -> Void) { reply(false, "not implemented") }
    func status(reply: @escaping (Data) -> Void) { reply(Data("{}".utf8)) }
    func stopTunnel(reply: @escaping (Bool) -> Void) { reply(true) }
}
```

> Note: reading `auditToken` via KVC is the documented workaround; if the KVC key is unavailable on the target OS, fall back to `xpc_connection_get_audit_token` on the private connection. Verify on-device in Task 6.

- [ ] **Step 2: Host the listener in main.swift**

```swift
// macos/Helper/main.swift
import Foundation
let service = HelperService()
let listener = NSXPCListener(machServiceName: HelperCodeRequirement.machServiceName)
listener.delegate = service
listener.resume()
RunLoop.main.run()
```

- [ ] **Step 3: Build the helper unsigned**

```bash
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -target DroidBridgeHelper -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add macos/Helper project.yml
git commit -m "feat(helper): XPC listener with signed-peer validation"
```

---

### Task 5: UtunDevice + UtunPacketSource

**Files:**
- Create: `macos/Helper/UtunDevice.swift`
- Create: `macos/Helper/UtunPacketSource.swift`
- Create: `scripts/utun-loopback-check.sh` (root local integration)

**Interfaces:**
- Consumes: `UtunFraming` (Task 2), `PacketSource` (Task 3).
- Produces: `final class UtunDevice { init() throws; let interfaceName: String; func read() -> Data?; func write(_ ipv4: Data); func close() }` and `final class UtunPacketSource: PacketSource` wrapping it on a read queue.

- [ ] **Step 1: Implement UtunDevice (open + framed read/write)**

```swift
// macos/Helper/UtunDevice.swift
import Foundation
import Darwin
import DroidBridgeShared

enum UtunError: Error { case open(String) }

final class UtunDevice {
    let fd: Int32
    let interfaceName: String

    init() throws {
        let s = socket(PF_SYSTEM, SOCK_DGRAM, SYSPROTO_CONTROL)
        guard s >= 0 else { throw UtunError.open("socket") }
        var info = ctl_info()
        _ = withUnsafeMutablePointer(to: &info.ctl_name) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: info.ctl_name)) { strcpy($0, "com.apple.net.utun_control") }
        }
        guard ioctl(s, CTLIOCGINFO, &info) >= 0 else { close(s); throw UtunError.open("ctliocginfo") }
        var addr = sockaddr_ctl(sc_len: UInt8(MemoryLayout<sockaddr_ctl>.size), sc_family: UInt8(AF_SYSTEM),
                                ss_sysaddr: UInt16(AF_SYS_CONTROL), sc_id: info.ctl_id, sc_unit: 0, sc_reserved: (0,0,0,0,0))
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_ctl>.size)) } }
        guard rc >= 0 else { close(s); throw UtunError.open("connect") }
        var name = [CChar](repeating: 0, count: 32); var len = socklen_t(name.count)
        _ = getsockopt(s, SYSPROTO_CONTROL, 2 /* UTUN_OPT_IFNAME */, &name, &len)
        self.fd = s
        self.interfaceName = String(cString: name)
    }

    func read() -> Data? {
        var buf = [UInt8](repeating: 0, count: 1500 + 4)
        let n = Darwin.read(fd, &buf, buf.count)
        guard n > 4 else { return nil }
        return UtunFraming.decode(Data(buf[0..<n]))
    }

    func write(_ ipv4: Data) {
        let frame = UtunFraming.encode(ipv4)
        frame.withUnsafeBytes { _ = Darwin.write(fd, $0.baseAddress, frame.count) }
    }

    func close() { Darwin.close(fd) }
}
```

```swift
// macos/Helper/UtunPacketSource.swift
import Foundation
import DroidBridgeShared

final class UtunPacketSource: PacketSource, @unchecked Sendable {
    private let device: UtunDevice
    private let queue = DispatchQueue(label: "io.droidbridge.utun.read")
    init(_ device: UtunDevice) { self.device = device }
    func read(_ handler: @escaping ([Data]) -> Void) {
        queue.async { if let p = self.device.read() { handler([p]) } else { handler([]) } }
    }
    func write(_ packets: [Data]) { for p in packets { device.write(p) } }
}
```

- [ ] **Step 2: Root local-integration script (self-open + ifconfig)**

```bash
# scripts/utun-loopback-check.sh — must run under sudo
#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "run under sudo" >&2; exit 2; }
bin="$1"   # path to a tiny test host that opens UtunDevice, prints interfaceName, assigns 198.18.0.2/30, waits
"$bin" &
pid=$!; sleep 1
ifconfig | grep -A2 "utun" | grep -q "198.18.0.2" && echo "PASS utun assigned" || { echo "FAIL"; kill $pid; exit 1; }
kill $pid
```

- [ ] **Step 3: Build unsigned + run the root check**

```bash
xcodegen generate && xcodebuild -project DroidBridge.xcodeproj -target DroidBridgeHelper -configuration Debug CODE_SIGNING_ALLOWED=NO build
# then run scripts/utun-loopback-check.sh against the built helper in a --selftest mode
```

Expected: interface `utunN` created, address assigned, `PASS utun assigned`.

- [ ] **Step 4: Commit**

```bash
git add macos/Helper/UtunDevice.swift macos/Helper/UtunPacketSource.swift scripts/utun-loopback-check.sh
git commit -m "feat(helper): utun device + packet source"
```

---

### Task 6: Route + pf controllers and helper data-plane assembly

**Files:**
- Create: `macos/Helper/RouteController.swift`, `macos/Helper/PfController.swift`
- Modify: `macos/Helper/HelperService.swift` (real start/stop wiring the tunnel)
- Create: `scripts/killswitch-check.sh` (root local integration)

**Interfaces:**
- Consumes: `RouteCommandBuilder`, `PfRuleBuilder` (Task 2), `UtunDevice`/`UtunPacketSource` (Task 5), `TunnelController` (Task 3), `TunnelStateMachine`/`TunnelSettingsDescriptor` (existing).
- Produces: `RouteController { func setDefault(utun:) throws; func restore() throws }`, `PfController { func enable(utun:physical:) throws; func disable() throws }`.

- [ ] **Step 1: Implement RouteController + PfController (execute the built argv)**

```swift
// macos/Helper/RouteController.swift
import Foundation
final class RouteController {
    private var savedGateway: String?
    private let run: ([String]) -> Int32
    init(run: @escaping ([String]) -> Int32 = RouteController.exec) { self.run = run }
    func setDefault(utun: String) throws {
        savedGateway = Self.currentDefaultGateway()
        for argv in RouteCommandBuilder(utun: utun).setDefault() where run(argv) != 0 {
            throw NSError(domain: "route", code: 1)
        }
    }
    func restore() throws {
        guard let gw = savedGateway else { return }
        for argv in RouteCommandBuilder(utun: "").restoreDefault(gateway: gw) where run(argv) != 0 {}
    }
    static func currentDefaultGateway() -> String? {
        // parse `route -n get default` "gateway:" line
        let p = Process(); p.launchPath = "/sbin/route"; p.arguments = ["-n","get","default"]
        let pipe = Pipe(); p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").first { $0.contains("gateway:") }?.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func exec(_ argv: [String]) -> Int32 {
        let p = Process(); p.launchPath = "/sbin/\(argv[0])"; p.arguments = Array(argv.dropFirst()); try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}
```

```swift
// macos/Helper/PfController.swift
import Foundation
final class PfController {
    func enable(utun: String, physical: [String]) throws {
        let body = PfRuleBuilder(utun: utun, physical: physical).anchorBody()
        let tmp = URL(fileURLWithPath: "/tmp/io.droidbridge.pf.conf")
        try body.write(to: tmp, atomically: true, encoding: .utf8)
        _ = shell("/sbin/pfctl", ["-a", "io.droidbridge", "-f", tmp.path])
        _ = shell("/sbin/pfctl", ["-E"])   // enable pf; idempotent
    }
    func disable() throws {
        _ = shell("/sbin/pfctl", ["-a", "io.droidbridge", "-F", "all"])
    }
    private func shell(_ path: String, _ args: [String]) -> Int32 {
        let p = Process(); p.launchPath = path; p.arguments = args; try? p.run(); p.waitUntilExit(); return p.terminationStatus
    }
}
```

- [ ] **Step 2: Wire start/stop in HelperService (fail-closed ordering)**

```swift
// HelperService.swift — replace the stub bodies
private var utun: UtunDevice?
private var controller: TunnelController?
private let route = RouteController()
private let pf = PfController()

func startTunnel(configJSON: Data, secret: Data, reply: @escaping (Bool, String?) -> Void) {
    do {
        let dev = try UtunDevice()
        try dev.assignAddress("198.18.0.2", peer: "198.18.0.1")     // add helper for ifconfig; see note
        let physical = NetworkInterfaces.physical()                  // ["en0", ...]
        try pf.enable(utun: dev.interfaceName, physical: physical)   // PROTECT FIRST
        try route.setDefault(utun: dev.interfaceName)                // THEN ROUTE
        let ctl = TunnelController(packetSource: UtunPacketSource(dev), secret: secret)
        ctl.start()
        self.utun = dev; self.controller = ctl
        reply(true, nil)
    } catch { reply(false, "\(error)") }
}

func stopTunnel(reply: @escaping (Bool) -> Void) {
    controller?.stop()
    try? route.restore()          // ROUTE FIRST
    try? pf.disable()             // THEN UNPROTECT
    utun?.close(); utun = nil; controller = nil
    reply(true)
}
```

> Notes: add `UtunDevice.assignAddress(_:peer:)` (calls `ifconfig utunN inet 198.18.0.2 198.18.0.1 up`) and a small `NetworkInterfaces.physical()` (parse `networksetup -listallhardwareports`). Both are thin shells; test their generated argv in Checks if convenient, exercise for real here.

- [ ] **Step 3: Kill-switch root integration**

```bash
# scripts/killswitch-check.sh — run under sudo, Mac Wi-Fi up, NO Android needed
#!/usr/bin/env bash
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "run under sudo" >&2; exit 2; }
# 1. baseline: en0 can reach a fixed IPv4
ping -c1 -t2 1.1.1.1 >/dev/null && echo "baseline egress ok"
# 2. load pf anchor for a fake utun + en0, WITHOUT a relay
pfctl -a io.droidbridge -f <(printf 'set block-policy drop\npass quick on lo0\nblock drop out quick on en0 all\n')
pfctl -E
# 3. egress must now fail (fail-closed)
if ping -c1 -t2 1.1.1.1 >/dev/null 2>&1; then echo "FAIL: leaked"; rc=1; else echo "PASS: egress blocked"; rc=0; fi
pfctl -a io.droidbridge -F all
exit $rc
```

Expected: baseline ok, then `PASS: egress blocked`, then egress restored.

- [ ] **Step 4: Build unsigned + run both root checks**

```bash
xcodegen generate && xcodebuild -project DroidBridge.xcodeproj -target DroidBridgeHelper -configuration Debug CODE_SIGNING_ALLOWED=NO build
sudo ./scripts/utun-loopback-check.sh <helper --selftest>
sudo ./scripts/killswitch-check.sh
make check-macos
```

Expected: both root checks PASS; Checks PASS.

- [ ] **Step 5: Commit**

```bash
git add macos/Helper scripts/killswitch-check.sh
git commit -m "feat(helper): route + pf kill-switch and fail-closed tunnel assembly"
```

---

### Task 7: App-side HelperClient + menu-bar wiring

**Files:**
- Create: `macos/HostApp/Helper/HelperClient.swift`
- Modify: `macos/HostApp/` menu-bar view/model (start/stop/status buttons → HelperClient)
- Modify: `project.yml` (embed helper in app bundle; add SMAppService plist)

**Interfaces:**
- Consumes: `DroidBridgeHelperProtocol`, `HelperCodeRequirement` (Task 2); the Task 1 registration decision.
- Produces: `final class HelperClient { func install() async throws; func start(config: TunnelConfig, secret: Data) async throws; func stop() async throws; func status() async -> TunnelMetricsSnapshot? }`.

- [ ] **Step 1: Implement HelperClient (install per Task 1 decision + XPC connect with peer pinning)**

```swift
// macos/HostApp/Helper/HelperClient.swift
import Foundation
import ServiceManagement
import DroidBridgeShared

final class HelperClient {
    private let requirement = HelperCodeRequirement.string(teamID: "ABCDE12345", bundleID: "io.droidbridge.macos")

    func install() async throws {
        // Task 1 decision == SMAppService:
        let service = SMAppService.daemon(plistName: "io.droidbridge.helper.plist")
        if service.status != .enabled { try service.register() }
        // Fallback path (if Task 1 == manual) documented in docs/spike-smappservice.md and used here instead.
    }

    private func connection() -> NSXPCConnection {
        let c = NSXPCConnection(machServiceName: HelperCodeRequirement.machServiceName, options: .privileged)
        c.remoteObjectInterface = NSXPCInterface(with: DroidBridgeHelperProtocol.self)
        if #available(macOS 13, *) { c.setCodeSigningRequirement(requirement) }
        c.resume()
        return c
    }

    func start(config: TunnelConfig, secret: Data) async throws {
        let json = try JSONEncoder().encode(config)
        let c = connection(); defer { c.invalidate() }
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            (c.remoteObjectProxy as? DroidBridgeHelperProtocol)?.startTunnel(configJSON: json, secret: secret) { ok, err in
                ok ? k.resume() : k.resume(throwing: NSError(domain: "helper", code: 1, userInfo: [NSLocalizedDescriptionKey: err ?? "start failed"]))
            }
        }
    }
    // stop() / status() analogous.
}
```

- [ ] **Step 2: Wire menu-bar Start/Stop to HelperClient**

In the existing HostApp menu-bar model, on Start: read secret from Keychain (existing store) + build `TunnelConfig` (existing) → `HelperClient.install()` then `.start(...)`; on Stop: `.stop()`. Poll `.status()` every 2 s to drive the status indicator (reuse `RelayHealthMonitor` cadence).

- [ ] **Step 3: Build unsigned (HostApp)**

```bash
xcodegen generate && xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add macos/HostApp project.yml
git commit -m "feat(app): helper client + menu-bar start/stop/status"
```

---

### Task 8: Signed build, embedding, and preflight

**Files:**
- Modify: `project.yml` (Helper entitlements, app `SMPrivilegedExecutables`, embed helper under `Contents/Library/LaunchDaemons` + `Contents/MacOS`)
- Modify: `scripts/build-signed-macos.sh` (build + verify helper signing, no NE entitlement on helper)
- Modify: `scripts/b1-preflight.sh` (add helper-install state check)

**Interfaces:**
- Consumes: everything above.
- Produces: a signed `DroidBridge.app` embedding a signed `DroidBridgeHelper`, verified by `codesign`.

- [ ] **Step 1: Add helper signing verification to build-signed-macos.sh**

```bash
# after the app build, in addition to the existing app/appex checks:
helper="$app/Contents/Library/LaunchDaemons/DroidBridgeHelper"   # actual embed path per project.yml
codesign -dv "$helper" 2>&1 | grep -q "TeamIdentifier=ABCDE12345" && echo "[PASS] helper signed by team" || { echo "[FAIL] helper signing"; rc=1; }
codesign -d --entitlements :- "$helper" 2>/dev/null | grep -q "networkextension" && { echo "[FAIL] helper must NOT carry NE entitlement"; rc=1; } || echo "[PASS] helper has no NE entitlement"
```

- [ ] **Step 2: Add helper-install check to b1-preflight.sh**

```bash
# new check: helper registered (SMAppService) or installed (manual)
if launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then hi=0; else hi=1; fi
record helper_installed "$(yn $hi)"
```

- [ ] **Step 3: Signed build**

```bash
DROIDBRIDGE_DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-signed-macos.sh
```

Expected: app + helper sign, `[PASS] helper signed`, `[PASS] helper has no NE entitlement`. (The dormant NE appex may fail provisioning on the free team — build the Helper/HostApp path with the appex excluded or unsigned; document in the script.)

- [ ] **Step 4: Commit**

```bash
git add project.yml scripts/build-signed-macos.sh scripts/b1-preflight.sh
git commit -m "build: sign + embed root helper, preflight helper check"
```

---

### Task 9: Device acceptance and release

**Files:**
- Create: `scripts/b1-functional.sh`, `scripts/b1-killswitch.sh`, `scripts/b1-stress.sh`, `scripts/b1-soak.sh`, `scripts/b1-performance.sh` (retarget the integration-release plan's scripts to app+helper launch; evidence via `tools/evidence.py`)
- Modify: memory + roadmap checkboxes

**Interfaces:**
- Consumes: signed app+helper, connected Android (preflight green).
- Produces: `build/evidence/*.json` for all 14 criteria; the `v0.1.0-b1` tag on pass.

- [ ] **Step 1: Preflight + install helper + start via app**

```bash
DROIDBRIDGE_DEVELOPMENT_TEAM=ABCDE12345 ./scripts/b1-preflight.sh   # must be green incl. helper_installed
```

- [ ] **Step 2: Functional (TCP + DNS + cellular exit)**

Bring the tunnel up via the app, then fetch a fixed IPv4 endpoint and confirm the public IP is the phone's cellular IP (compare against the Android instrumentation baseline, not just a public-IP lookup). Confirm DNS resolves through the tunnel. Write redacted evidence.
Expected: `build/evidence/functional.json` `passed=true`.

- [ ] **Step 3: Kill-switch (real leak test)**

With the tunnel up and Mac Wi-Fi on, run `tcpdump -i en0 host <fixed IPv4>` while pulling USB / killing the relay; assert **zero packets** to the fixed IPv4 on en0 and that new connections fail closed. Restore and confirm recovery.
Expected: `build/evidence/killswitch.json` `passed=true`, zero-leak.

- [ ] **Step 4: Stress + soak + performance**

128 concurrent TCP flows; 1-hour soak cycling DNS/short-TCP/long-download/reconnect with both-side memory sampling; throughput + added-RTT vs the Android baseline on the same server. Block criteria: <20 Mbps or added RTT median >40 ms.
Expected: three evidence JSONs `passed=true`.

- [ ] **Step 5: Tag the release (only if all 14 pass)**

```bash
git tag -a v0.1.0-b1 -m "DroidBridge B1: NE-free utun helper full-tunnel, all acceptance criteria green"
```

- [ ] **Step 6: Commit evidence scripts + update memory/roadmap**

```bash
git add scripts/b1-*.sh docs/superpowers/plans/2026-09-21-droidbridge-b1-roadmap.md
git commit -m "test: b1 device acceptance on utun helper; tag v0.1.0-b1"
```

---

## Self-Review

- **Spec coverage:** §4 arch → Tasks 3-7; §5 data flow / utun framing → Tasks 2,5; §6 privilege/lifecycle → Tasks 1,4,7; §7 kill-switch/ordering → Tasks 2,6; §8 components → Tasks 3-8; §9 testing → every task's checks + Task 9; §10 acceptance → Task 9; §11 risks (SMAppService) → Task 1 spike. All covered.
- **Placeholder scan:** low-level bodies (utun open, pf/route, XPC validation) are spelled out; reuse-heavy delegate bodies are explicitly "unchanged from the existing file" (not new code). No TBD/TODO.
- **Type consistency:** `PacketSource`/`PacketIngesting` (Task 3) used consistently in Tasks 5-6; `DroidBridgeHelperProtocol`/`HelperCodeRequirement` (Task 2) used in Tasks 4,7; `RouteCommandBuilder`/`PfRuleBuilder` (Task 2) used in Task 6; mach service name `io.droidbridge.helper` consistent across Tasks 2,4,7,8.
- **Calibration flags:** utun AF-header endianness, `UTUN_OPT_IFNAME=2`, and the `auditToken` KVC key are hardware-verified in Tasks 5-6, not assumed correct at desk time.
