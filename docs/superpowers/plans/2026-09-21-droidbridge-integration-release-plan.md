# DroidBridge B1 Integration, Security, and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 실제 Apple Silicon Mac과 실제 Android 단말에서 DroidBridge B1의 기능, 셀룰러 출구, fail-closed 동작, 보안 경계, 128-flow·1시간 안정성, 20 Mbps/40 ms 성능 기준을 검증하고 재현 가능한 `v0.1.0-b1` 개발자용 릴리스를 만든다.

**Architecture:** signed HostApp/PacketTunnel과 Android debug/release APK를 실제 USB 경로에서 시험한다. 모든 수용 시험은 `scripts/b1-*.sh`가 증거 JSON을 `build/evidence/`에 기록하도록 구성하되 secret·payload·DNS name은 제외한다. 성능은 사용자가 통제하는 인터넷상의 benchmark server와 Android instrumentation baseline을 비교한다.

**Tech Stack:** signed Xcode build, Android Gradle, Bash, Python 3.11 asyncio/TLS benchmark tools, tcpdump, adb, codesign, XCTest/JUnit, JSON evidence manifests

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`

## Global Constraints

- 실제 수용 시험은 본인 소유 Mac, Android, SIM/회선과 본인이 통제하는 benchmark server에서만 수행한다.
- Network Extension을 실제 실행할 수 있는 Apple Development signing team과 entitlement가 필요하다.
- Mac은 Apple Silicon, macOS 14 이상이어야 하고 Android는 API 26 이상·활성 모바일 데이터가 필요하다.
- 기능 시험은 Android Wi-Fi OFF/Mobile Data ON과 Android Wi-Fi ON/Mobile Data ON 두 조건에서 수행한다.
- kill-switch 시험은 Mac Wi-Fi가 켜져 있고 인터넷 사용 가능한 상태에서도 USB/cellular 장애 후 누출이 없어야 통과한다.
- evidence에는 시각, 버전, 상태, byte count, latency, exit code, interface만 저장하며 payload·secret·URL path·DNS query name은 저장하지 않는다.
- 성능 차단 기준은 실제 처리량 20 Mbps 미만 또는 tunnel 추가 RTT median 40 ms 초과다.
- 목표치는 50 Mbps 이상, 추가 RTT median 15 ms 이하다.
- 128 concurrent TCP flow와 1시간 soak 모두 통과해야 한다.
- TTL, APN, DUN, carrier entitlement 설정을 변경하는 코드·스크립트가 없어야 한다.
- 모든 수용 기준을 충족하기 전에는 release tag를 만들지 않는다.

## Review Focus

- public-IP 조회 결과만으로 셀룰러 출구를 단정하지 말고 Android mobile-data baseline, Wi-Fi-on 조건, cellular-off failure를 함께 증명해야 한다.
- tcpdump 증거가 잘못된 interface나 DNS 이름 재해석 때문에 누출을 놓치지 않도록 고정 IPv4 목적지와 실제 Wi-Fi interface를 기록해야 한다.
- benchmark server 자체 성능·거리 변동을 tunnel overhead로 오판하지 않도록 Android instrumentation baseline을 같은 server·짧은 시간창에서 먼저 측정해야 한다.
- 1시간 soak가 단순 idle이 아니라 DNS, 짧은 TCP, 장기 download, reconnect를 반복하고 양쪽 메모리 증가를 기록해야 한다.
- release archive에 Keychain dump, temporary pairing file, signing certificate private material, evidence payload가 포함되지 않아야 한다.

---

### Task 1: Signed-build and entitlement preflight

**Files:**
- Create: `scripts/b1-preflight.sh`
- Create: `scripts/build-signed-macos.sh`
- Create: `scripts/build-android-release.sh`
- Create: `tools/evidence.py`
- Create: `tools/tests/test_evidence.py`
- Create: `docs/signing-setup.md`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `DROIDBRIDGE_DEVELOPMENT_TEAM`, one authorized Android device, generated Xcode project.
- Produces: signed HostApp/PacketTunnel, Android APK, redacted evidence writer, preflight JSON.

- [ ] **Step 1: Write the failing evidence redaction tests**

```python
class EvidenceTest(unittest.TestCase):
    def test_rejects_sensitive_keys_recursively(self) -> None:
        with self.assertRaises(SensitiveEvidenceError):
            write_evidence({"result": {"pairingSecret": "deadbeef"}}, self.path)

    def test_allows_only_declared_scalar_types(self) -> None:
        write_evidence({
            "test": "preflight",
            "passed": True,
            "timestamp": "2026-09-21T00:00:00Z",
            "metrics": {"latencyMs": 12.5, "bytes": 1024},
        }, self.path)
        self.assertTrue(self.path.exists())
```

Sensitive key matching is case-insensitive and includes `secret`, `token`, `password`, `payload`, `cookie`, `authorization`, `sni`, `dnsName`, `url`.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_evidence -v
```

- [ ] **Step 3: Implement exact preflight checks**

`b1-preflight.sh` fails unless all are true:

```text
uname -m == arm64
macOS major >= 14
xcodebuild, xcodegen 2.46.0, cmake >= 3.28, python >= 3.11 available
DROIDBRIDGE_DEVELOPMENT_TEAM non-empty
exactly one adb device in authorized state
Android API >= 26
package io.droidbridge.android installed
mobile data enabled and a TRANSPORT_CELLULAR network visible
Mac Wi-Fi interface identified through networksetup
no process listens on host ports 27183 or 27184 before setup
working tree clean
all foundation/Android/Swift unit tests pass
```

`build-signed-macos.sh` runs XcodeGen and builds with the supplied team into `build/DerivedData`. It then verifies with `codesign -d --entitlements :-` that HostApp and extension share `group.io.droidbridge.shared`, the extension has packet-tunnel-provider entitlement, and both use the intended keychain group.

`build-android-release.sh` runs unit/lint tests and produces a locally signed developer APK; signing credentials are read from Gradle properties outside the repository or use the debug key for local-only testing. No keystore is copied into `build/release`.

- [ ] **Step 4: Run preflight and build**

```bash
./scripts/b1-preflight.sh
./scripts/build-signed-macos.sh
./scripts/build-android-release.sh
```

Expected: `build/evidence/preflight.json` contains only safe environment/version/check results and both artifacts pass signature inspection.

- [ ] **Step 5: Commit**

```bash
git add scripts tools/evidence.py tools/tests/test_evidence.py docs/signing-setup.md Makefile
git commit -m "build: add signed b1 preflight and redacted evidence"
```

### Task 2: End-to-end TCP, DNS, and cellular-exit functional acceptance

**Files:**
- Create: `scripts/b1-functional.sh`
- Create: `tools/public_exit_probe.py`
- Create: `tools/tests/test_public_exit_probe.py`
- Create: `docs/b1-functional-test.md`

**Interfaces:**
- Consumes: running signed DroidBridge tunnel and Android mobile data.
- Produces: evidence for HTTPS, Git HTTPS, SSH TCP, DNS, Android Wi-Fi ON cellular binding and external exit comparison.

- [ ] **Step 1: Write probe parser tests**

`public_exit_probe.py` accepts JSON from a configurable HTTPS IP service but records only IPv4 and optional ASN string. Tests reject IPv6-only results, private/reserved addresses, HTML, extra-large responses and malformed JSON.

```python
def test_accepts_public_ipv4() -> None:
    result = parse_probe(b'{"ip":"203.0.113.9","asn":"AS64500"}')
    # Documentation ranges are deliberately rejected as non-public in production.
    assert result.error == "non_public_address"
```

Use `93.184.216.34` only in parser fixtures marked public for unit-test dependency injection; production policy uses `ipaddress.ip_address(...).is_global`.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_public_exit_probe -v
```

- [ ] **Step 3: Implement the functional script**

The script requires environment variable `DROIDBRIDGE_IP_PROBE_URL` pointing to an HTTPS endpoint that returns `{"ip":"A.B.C.D","asn":"AS..."}` and is approved by the operator. It performs:

```text
1. Android Wi-Fi OFF, mobile data ON; operator records Android baseline IP/ASN through the same endpoint.
2. Mac Wi-Fi and Ethernet OFF; connect DroidBridge.
3. resolve a fixed test hostname through the virtual DNS.
4. HTTPS GET with curl --http1.1 and --connect-timeout 10.
5. git ls-remote over HTTPS against a small public repository or operator-controlled Git endpoint.
6. SSH TCP handshake to an operator-controlled SSH endpoint; authentication success is not required.
7. query Mac exit IP/ASN and compare it to Android baseline ASN or operator-confirmed carrier range.
8. Android Wi-Fi ON while mobile data remains ON; repeat exit probe and HTTPS.
9. Android mobile data OFF while Wi-Fi remains ON; requests must fail and HostApp must show blocked cellular, not use Android Wi-Fi.
10. restore mobile data and reconnect explicitly; HTTPS succeeds again.
```

Mac Wi-Fi may be turned back on for steps 8-10 only after initial no-other-interface functionality is proven. Record command exit codes, selected interfaces, DBP health state and IP/ASN; do not record response bodies.

- [ ] **Step 4: Execute the functional acceptance**

```bash
DROIDBRIDGE_IP_PROBE_URL='https://operator.example/ip-json' \
DROIDBRIDGE_GIT_URL='https://operator.example/small.git' \
DROIDBRIDGE_SSH_HOST='operator.example' \
./scripts/b1-functional.sh
```

Expected evidence assertions:

```text
https = pass
git_https = pass
ssh_tcp = pass
dns = pass
mac_no_wifi = pass
android_wifi_on_still_cellular = pass
cellular_off_fails_closed = pass
exit_asn_matches_baseline = pass
```

The literal example hostnames above are argument examples; the script refuses `.example` values and requires operator-controlled real endpoints.

- [ ] **Step 5: Commit**

```bash
git add scripts/b1-functional.sh tools/public_exit_probe.py tools/tests/test_public_exit_probe.py docs/b1-functional-test.md
git commit -m "test: automate b1 functional cellular acceptance"
```

### Task 3: Fail-closed fault injection and interface leak detection

**Files:**
- Create: `scripts/b1-killswitch.sh`
- Create: `tools/leak_analyzer.py`
- Create: `tools/tests/test_leak_analyzer.py`
- Create: `docs/b1-killswitch-test.md`

**Interfaces:**
- Consumes: a fixed operator-controlled public IPv4 endpoint, Wi-Fi interface, signed running tunnel.
- Produces: pcap metadata analysis and state evidence for USB removal, Android process death, cellular loss, Mac sleep/wake and relay recovery.

- [ ] **Step 1: Write failing leak-analyzer tests**

Feed a minimal text-converted tcpdump fixture:

```python
def test_flags_destination_packet_on_wifi_after_fault_timestamp() -> None:
    events = parse_tcpdump([
        "1700000000.100000 IP 192.0.2.2.50000 > 198.51.100.20.443: Flags [S]",
    ])
    result = analyze(events, fault_timestamp=1700000000.0,
                     forbidden_interface="en0", destination="198.51.100.20")
    assert result.leaked_packets == 1
```

Also test pre-fault packets ignored, unrelated destinations ignored, IPv6 ignored for B1 report, empty capture passes only when request attempts were recorded separately.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_leak_analyzer -v
```

- [ ] **Step 3: Implement fault scenarios and capture discipline**

`b1-killswitch.sh` requires `DROIDBRIDGE_FAULT_HOST` and resolves it once to one public IPv4 before starting. It enables Mac Wi-Fi and verifies it has ordinary internet connectivity before connecting DroidBridge. Start:

```bash
sudo tcpdump -ni "$WIFI_INTERFACE" -tt -l "host $FAULT_IP and tcp" \
  > build/evidence/killswitch-wifi.txt
```

Run a one-second repeated TCP connect loop through the tunnel, record a monotonic and wall-clock fault marker, then test separately:

1. physically remove USB or operator confirms cable disconnect prompt;
2. `adb shell am force-stop io.droidbridge.android`;
3. disable Android mobile data while keeping Android Wi-Fi on;
4. sleep Mac for at least 15 seconds and wake with USB still connected;
5. restore the failed component and observe bounded 1/2/4-second reconnect or persistent block after three failures.

For each fault, within 3 seconds HostApp/provider must report a blocked state; connect attempts must fail; analyzer must find zero destination packets on Wi-Fi after the fault marker. Default route may still list the VPN interface; settings must not be removed until explicit Disconnect.

- [ ] **Step 4: Execute and inspect evidence**

```bash
DROIDBRIDGE_FAULT_HOST='operator-controlled-host' ./scripts/b1-killswitch.sh
python3 tools/leak_analyzer.py build/evidence/killswitch-wifi.txt \
  --faults build/evidence/killswitch-markers.json
```

Expected: all four fault scenarios show `leakedPackets=0`, `blockedWithinMs<=3000`, and no automatic fallback to Mac Wi-Fi or Android Wi-Fi.

- [ ] **Step 5: Commit**

```bash
git add scripts/b1-killswitch.sh tools/leak_analyzer.py tools/tests/test_leak_analyzer.py docs/b1-killswitch-test.md
git commit -m "test: verify packet tunnel fail closed under faults"
```

### Task 4: Security boundary and negative protocol acceptance

**Files:**
- Create: `scripts/b1-security.sh`
- Create: `tools/dbp_negative_suite.py`
- Create: `tools/tests/test_dbp_negative_suite.py`
- Create: `docs/threat-model.md`
- Create: `docs/security-test-results.md`

**Interfaces:**
- Consumes: paired/running relay and probe tools.
- Produces: verified loopback-only bind, auth/replay/policy/session-limit behavior, secret/log/static source checks and threat model.

- [ ] **Step 1: Write negative-suite unit tests**

The suite must build cases for bad magic, 63-byte header, header length 65, unknown type, wrong HMAC, timestamp ±121 seconds, replayed HELLO nonce, zero port, domain length 254, private IPv4, domain resolving private-only, and 129th session.

Mock tests assert each maps to the expected DBP error or connection close and never hangs longer than 3 seconds.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_dbp_negative_suite -v
```

- [ ] **Step 3: Implement security script**

The script:

```text
- uses adb shell ss -ltn or /proc/net/tcp to prove device port 27183 listens on 127.0.0.1 only;
- runs the complete DBP negative suite through adb forward;
- opens 128 authenticated test sessions and proves session 129 returns SESSION_LIMIT;
- requests every blocked CIDR representative and expects POLICY_DENIED;
- reuses a HELLO nonce on a new connection and expects AUTH_FAILED/close;
- scans repository and release staging for 64-hex test/real secret patterns, temporary pairing files and forbidden sensitive evidence keys;
- runs log stream/logcat during traffic and verifies known test marker payload never appears;
- searches source/scripts for TTL, ip_default_ttl, hoplimit, APN database writes, DUN setting changes, carrier entitlement bypass strings;
- confirms no listener is reachable from Android Wi-Fi interface address.
```

Static search findings are reviewed contextually: documentation explaining forbidden functionality is allowed, executable modification code is not.

Write `docs/threat-model.md` with assets, trust boundaries, local malicious process, malicious paired Mac, compromised Android, ADB exposure, DNS rebinding, relay abuse, route leak, log disclosure and dependency risks; map each to mitigation and residual risk.

- [ ] **Step 4: Run the security acceptance**

```bash
./scripts/b1-security.sh
```

Expected: every negative case is rejected, no sensitive marker appears in logs/artifacts, and loopback-only binding is proven.

- [ ] **Step 5: Commit**

```bash
git add scripts/b1-security.sh tools/dbp_negative_suite.py tools/tests/test_dbp_negative_suite.py docs/threat-model.md docs/security-test-results.md
git commit -m "test: validate b1 authentication and relay boundaries"
```

### Task 5: Controlled benchmark server and direct-cellular baseline

**Files:**
- Create: `tools/benchmark/server.py`
- Create: `tools/benchmark/client.py`
- Create: `tools/benchmark/Dockerfile`
- Create: `tools/benchmark/protocol.md`
- Create: `tools/tests/test_benchmark_protocol.py`
- Create: `android/app/src/androidTest/java/io/droidbridge/benchmark/CellularBenchmarkInstrumentedTest.kt`
- Create: `scripts/b1-performance.sh`

**Interfaces:**
- Consumes: operator-controlled internet host with TLS certificate and TCP port, Android cellular Network, running Mac tunnel.
- Produces: direct Android median RTT, tunnel median RTT, added RTT, sustained throughput and evidence.

- [ ] **Step 1: Write benchmark protocol tests**

The binary protocol is:

```text
4 bytes magic "DBB1"
1 byte operation: 1=PING, 2=DOWNLOAD, 3=ECHO
8 bytes unsigned requested byte count
8 bytes unsigned nonce
```

PING response echoes the 21-byte request. DOWNLOAD response begins with the same header then exactly requested deterministic bytes generated from the nonce, capped at 2 GiB. Tests cover partial reads, count 0, >2 GiB rejection, wrong magic, timeout and digest mismatch.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_benchmark_protocol -v
```

- [ ] **Step 3: Implement server, clients and Android baseline test**

`server.py` uses asyncio TLS, limits 16 concurrent clients, 64 KiB chunks and 30-second idle timeout. It logs only operation, byte count, duration and peer ASN-unaware IP prefix redacted to `/24`; payload is deterministic and not retained.

Android instrumentation receives host/port via runner arguments, requests the current cellular network, creates its socket through `network.socketFactory`, performs 30 PING exchanges, discards five warmups and prints median/p95 in one machine-readable line:

```text
DROIDBRIDGE_BENCHMARK {"medianRttMs":12.4,"p95RttMs":18.9}
```

Mac client performs the same 30 PING exchanges through the active tunnel and a 512 MiB DOWNLOAD while recording wall time and SHA-256.

`b1-performance.sh` runs Android baseline and Mac test within five minutes, calculates `addedRtt = macMedian - androidMedian`, and fails below 20 Mbps or above 40 ms. It marks target attainment separately at 50 Mbps/15 ms.

- [ ] **Step 4: Execute controlled performance test**

Deploy the Docker image to an operator-controlled internet host, then run:

```bash
DROIDBRIDGE_BENCH_HOST='bench.operator-domain' \
DROIDBRIDGE_BENCH_PORT='443' \
./scripts/b1-performance.sh
```

Expected release gate:

```text
throughputMbps >= 20
addedMedianRttMs <= 40
sha256Verified = true
cellularBaselineNetwork = TRANSPORT_CELLULAR
```

- [ ] **Step 5: Commit**

```bash
git add tools/benchmark tools/tests/test_benchmark_protocol.py android/app/src/androidTest/java/io/droidbridge/benchmark scripts/b1-performance.sh
git commit -m "test: measure cellular tunnel throughput and overhead"
```

### Task 6: 128-flow concurrency, 1 GiB transfer, and one-hour soak

**Files:**
- Create: `tools/benchmark/soak.py`
- Create: `tools/tests/test_soak_scheduler.py`
- Create: `scripts/b1-soak.sh`
- Create: `docs/b1-soak-test.md`

**Interfaces:**
- Consumes: benchmark server and active tunnel.
- Produces: 128-flow result, 1 GiB integrity transfer, 60-minute mixed workload, memory/flow cleanup evidence.

- [ ] **Step 1: Write deterministic workload scheduler tests**

The scheduler must produce each five-minute cycle:

```text
60 short PING connections
20 short ECHO connections
1 continuous DOWNLOAD segment
1 DNS resolution check
one burst of 128 concurrent ECHO flows every 15 minutes
```

Tests use a fake clock to assert exactly 12 cycles in 60 minutes, cancellation cleanup, no task count drift and seeded deterministic operation order.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_soak_scheduler -v
```

- [ ] **Step 3: Implement soak and resource sampling**

Before soak, transfer exactly 1 GiB from the benchmark server and verify SHA-256. For the concurrency gate, open 128 flows, hold each for 10 seconds, exchange 4 KiB each direction, then close and verify HostApp metrics return to zero within 15 seconds.

During soak sample every minute:

```text
PacketTunnel RSS via ps
HostApp RSS
Android service PSS via adb shell dumpsys meminfo
active flow count
cumulative bytes
health state
failed/succeeded operations
```

Fail on extension/service crash, blocked state not caused by an injected test, payload digest mismatch, active flow leak after a cycle, or monotonic RSS growth exceeding 50 MiB after the first 10-minute warmup without returning within 10 MiB.

- [ ] **Step 4: Execute soak**

```bash
DROIDBRIDGE_BENCH_HOST='bench.operator-domain' \
DROIDBRIDGE_BENCH_PORT='443' \
./scripts/b1-soak.sh --duration 60m
```

Expected: 1 GiB verified, 128 flows pass, 60-minute workload completes, active flows return to zero and both memory ceilings remain under spec limits.

- [ ] **Step 5: Commit**

```bash
git add tools/benchmark/soak.py tools/tests/test_soak_scheduler.py scripts/b1-soak.sh docs/b1-soak-test.md
git commit -m "test: validate 128 flows and one hour stability"
```

### Task 7: Operations guide, privacy review, release packaging, and acceptance manifest

**Files:**
- Create: `docs/operations.md`
- Create: `docs/privacy.md`
- Create: `docs/troubleshooting.md`
- Create: `CHANGELOG.md`
- Create: `scripts/package-b1.sh`
- Create: `scripts/verify-b1-acceptance.py`
- Create: `docs/b1-acceptance.json`
- Modify: `README.md`

**Interfaces:**
- Consumes: all evidence JSON files and built artifacts.
- Produces: scrubbed release directory, SHA-256 manifest and machine-verified 14-criterion acceptance record.

- [ ] **Step 1: Write failing acceptance-verifier tests**

Create fixtures proving the verifier fails when any criterion is absent, false, stale relative to current git commit, generated on a different source revision, or references missing evidence. It passes only when all 14 IDs from spec section 16 are true.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_acceptance_verifier -v
```

- [ ] **Step 3: Implement documentation and packaging**

`operations.md` documents install, pair, Start, Connect, blocked states, explicit Disconnect, unpair, upgrade and uninstall. `privacy.md` enumerates collected/not-collected data. `troubleshooting.md` covers ADB unauthorized, multiple devices, missing entitlement, relay unavailable, cellular unavailable, port conflict and sleep/wake.

`package-b1.sh` creates:

```text
build/release/DroidBridge-0.1.0-b1/
  DroidBridgeHost.app
  DroidBridge-android.apk
  README.md
  LICENSE
  THIRD_PARTY_NOTICES.md
  operations.md
  SHA256SUMS
  source-revision.txt
```

It rejects symlinks escaping the directory, `.env`, keystore files, provisioning private material, `build/evidence`, pairing temp files, logs and files containing sensitive evidence keys. It signs the checksum manifest with no embedded private key requirement; local optional signing is documented separately.

`verify-b1-acceptance.py` maps each of the 14 spec criteria to exact evidence assertions and writes `docs/b1-acceptance.json` containing git revision, artifact hashes and test timestamps.

- [ ] **Step 4: Run final acceptance and package verification**

```bash
python3 scripts/verify-b1-acceptance.py --evidence build/evidence --output docs/b1-acceptance.json
./scripts/package-b1.sh
shasum -a 256 -c build/release/DroidBridge-0.1.0-b1/SHA256SUMS
```

Expected: all 14 criteria true and every checksum verifies.

- [ ] **Step 5: Commit and tag only after all checks pass**

```bash
git add README.md CHANGELOG.md docs scripts/package-b1.sh scripts/verify-b1-acceptance.py
git commit -m "release: prepare droidbridge b1 artifacts"
git tag -a v0.1.0-b1 -m "DroidBridge B1"
```

## Final B1 verification command

Run in a clean checkout with submodules initialized:

```bash
./scripts/b1-preflight.sh
./scripts/verify-data-plane.sh
./scripts/b1-functional.sh
./scripts/b1-killswitch.sh
./scripts/b1-security.sh
./scripts/b1-performance.sh
./scripts/b1-soak.sh --duration 60m
python3 scripts/verify-b1-acceptance.py --evidence build/evidence --output docs/b1-acceptance.json
./scripts/package-b1.sh
git status --short
```

B1 is complete only if all commands pass, `docs/b1-acceptance.json` contains fourteen true criteria for the current git revision, release checksums verify, and `git status --short` is empty.
