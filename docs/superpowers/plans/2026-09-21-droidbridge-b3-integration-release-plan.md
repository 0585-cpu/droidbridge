# DroidBridge B3 Integration, Resilience, and Stable Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 실제 dual-stack/IPv4-only Android 기기와 통제된 서버에서 B3 20개 수용 기준을 검증하고 `v0.3.0-b3`와 동일 commit의 `v1.0.0` artifact를 만든다.

**Architecture:** acceptance harness는 IPv4/IPv6 TCP·UDP·HTTP3, optional NAT64, ICMP capability, LAN route boundary, USB/sleep/cellular fault를 분리 측정한다. manifest는 기기 capability 차이를 그대로 기록하며 unsupported ICMP를 허위 성공으로 처리하지 않는다.

**Tech Stack:** Python 3.11+, Docker, IPv6-capable controlled server, shell, signed macOS/Android builds, packet-header leak analyzer

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b3-dual-stack-resilience-design.md`

## Global Constraints

- controlled server와 local LAN device는 모두 사용자 소유 또는 명시적 허가 대상이다.
- B1/B2 acceptance를 같은 commit에서 재실행한다.
- IPv6 unavailable test는 실제 unavailable 기기 또는 isolated test profile로 수행한다.
- packet capture evidence는 header count/route만 저장하고 payload를 폐기한다.
- ICMP unsupported device는 explicit unavailable이면 PASS 가능하지만 false positive는 FAIL이다.
- `v1.0.0`은 `v0.3.0-b3`와 동일 source commit에서 생성한다.

## Review Focus

- dual-stack server의 IPv4 fallback이 IPv6 성공으로 잘못 기록되지 않아야 한다.
- IPv6 leak test가 utun과 physical interface를 동시에 관찰해야 한다.
- LAN bypass test가 표시된 subnet 밖의 RFC1918/public route를 허용하지 않아야 한다.
- reconnect test에서 old TCP failure를 버그로 오판하지 말고 new-flow recovery를 분리 측정해야 한다.
- 8시간 soak의 capability/route changes가 evidence 순서와 monotonic generation을 유지해야 한다.

---

### Task 1: B3 acceptance schema, capability matrix, and preflight

**Files:**
- Create: `docs/b3-acceptance.json`
- Create: `docs/b3-device-matrix.json`
- Create: `scripts/b3-preflight.sh`
- Create: `scripts/verify-b3-acceptance.py`
- Create: `tools/tests/test_b3_acceptance_schema.py`
- Modify: `Makefile`

**Interfaces:**
- Consumes: B1/B2 PASS manifests, signed B3 builds, device/server inventory.
- Produces: 20-item B3 manifest and capability-aware preflight.

- [ ] **Step 1: Write failing schema tests**

```python
class B3SchemaTests(unittest.TestCase):
    def test_exact_criteria_and_icmp_capability_evidence(self):
        manifest = load("docs/b3-acceptance.json")
        self.assertEqual([c["id"] for c in manifest["criteria"]], [f"B3-{i:02d}" for i in range(1, 21)])
        matrix = load("docs/b3-device-matrix.json")
        self.assertTrue(all("icmp4_probe" in d and "icmp6_probe" in d for d in matrix["devices"]))
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b3_acceptance_schema -v
```

Expected: FAIL because B3 schema/matrix do not exist.

- [ ] **Step 3: Implement preflight**

Preflight verifies B1/B2 manifests, signed dual-stack Network Extension, Android app native arm64 library, one dual-stack or NAT64-controlled path, one IPv4-only/unavailable profile, controlled IPv6 server, optional LAN test host, and sleep/wake test permission. It records exact device model/OS/capability without subscriber identifiers.

- [ ] **Step 4: Run preflight**

```bash
python3 -m unittest tools.tests.test_b3_acceptance_schema -v
make b3-preflight
```

Expected: schema PASS and preflight gives specific environment result.

- [ ] **Step 5: Commit**

```bash
git add docs scripts tools/tests Makefile
git commit -m "test(release): define B3 capability-aware acceptance"
```

---

### Task 2: Controlled dual-stack, NAT64-policy, and ICMP test services

**Files:**
- Create: `tools/b3-server/docker-compose.yml`
- Create: `tools/b3-server/dual_stack_echo.py`
- Create: `tools/b3-server/http3/Caddyfile`
- Create: `tools/b3-server/dns_authority.py`
- Create: `tools/b3-server/icmp_expectations.json`
- Create: `tools/tests/test_b3_server_protocols.py`
- Create: `docs/b3-controlled-server.md`

**Interfaces:**
- Consumes: user-controlled IPv4+IPv6 host and authoritative test zone.
- Produces: TCP/UDP4/6 echo, HTTP3 v4/v6, DNS A/AAAA/SVCB/DNSSEC fixtures.

- [ ] **Step 1: Write failing DNS fixture tests**

```python
class B3ServerProtocolTests(unittest.TestCase):
    def test_zone_contains_dual_stack_and_signed_aaaa_cases(self):
        zone = build_test_zone("droidbridge.test")
        self.assertIn("A", zone["dual"])
        self.assertIn("AAAA", zone["dual"])
        self.assertIn("RRSIG", zone["signed-aaaa"])
        self.assertIn("HTTPS", zone["svc"])
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b3_server_protocols -v
```

Expected: FAIL because B3 service files do not exist.

- [ ] **Step 3: Implement services**

Bind TCP/UDP echo separately to `0.0.0.0` and `::`, log only aggregate counters, and publish health showing actual family. DNS authority serves A, AAAA, SVCB ipv4hint/ipv6hint, blocked documentation/private fixtures, and a signed AAAA response. HTTP3 serves deterministic objects with family echoed in a response header.

- [ ] **Step 4: Run local validation**

```bash
python3 -m unittest tools.tests.test_b3_server_protocols -v
docker compose -f tools/b3-server/docker-compose.yml config
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tools/b3-server tools/tests docs/b3-controlled-server.md
git commit -m "test(release): add controlled B3 dual-stack services"
```

---

### Task 3: IPv6 TCP/UDP/DNS functional and leak acceptance

**Files:**
- Create: `scripts/b3-dual-stack.sh`
- Create: `tools/b3_dual_stack_probe.py`
- Create: `tools/tests/test_b3_dual_stack_probe.py`
- Create: `docs/b3-dual-stack-test.md`

**Interfaces:**
- Consumes: connected B3 tunnel, controlled server, packet-header capture.
- Produces: B3-01...B3-06 evidence.

- [ ] **Step 1: Write failing family-proof tests**

```python
class DualStackProbeTests(unittest.TestCase):
    def test_ipv6_success_requires_ipv6_peer_and_server_header(self):
        result = classify(connection_peer="2001:db8::10", server_family_header="ipv6")
        self.assertEqual(result, "ipv6")
        with self.assertRaises(ValueError):
            classify(connection_peer="192.0.2.10", server_family_header="ipv6")
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b3_dual_stack_probe -v
```

Expected: FAIL because probe does not exist.

- [ ] **Step 3: Implement explicit family tests**

The script performs IPv6 literal TCP, IPv6 literal UDP, AAAA DNS, dual-stack hostname, HTTP3 over IPv6, NAT64 public/private embedded policy, then repeats with Android IPv6 unavailable. Leak capture watches all non-utun physical interfaces for IPv6 packets during unavailable/blocked windows and requires zero matching egress.

- [ ] **Step 4: Run dual-stack acceptance**

```bash
: "${DROIDBRIDGE_B3_SERVER:?set DROIDBRIDGE_B3_SERVER to the controlled server}"
DROIDBRIDGE_B3_ZONE=droidbridge.test make b3-dual-stack
```

Expected: B3-01...B3-06 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): verify B3 dual-stack and IPv6 leak prevention"
```

---

### Task 4: ICMP capability and echo correctness acceptance

**Files:**
- Create: `scripts/b3-icmp.sh`
- Create: `tools/icmp_packet_verifier.py`
- Create: `tools/tests/test_icmp_packet_verifier.py`
- Create: `docs/b3-icmp-test.md`

**Interfaces:**
- Consumes: Android reported ICMP capabilities and controlled echo target.
- Produces: B3-07...B3-09 evidence.

- [ ] **Step 1: Write failing identifier/sequence verifier tests**

```python
class ICMPVerifierTests(unittest.TestCase):
    def test_reply_must_match_identifier_sequence_and_payload_digest(self):
        request = EchoRecord(family=4, identifier=0x1234, sequence=9, payload_sha256="aa")
        response = EchoRecord(family=4, identifier=0x1234, sequence=9, payload_sha256="aa")
        self.assertTrue(matches(request, response))
        self.assertFalse(matches(request, dataclasses.replace(response, sequence=10)))
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_icmp_packet_verifier -v
```

Expected: FAIL because verifier does not exist.

- [ ] **Step 3: Implement capability-aware test**

For each family, first compare Android probe result with Host UI/health capability. If available, send 20 echo requests with unique identifier/sequence/payload and verify replies and RTT. If unavailable, verify Mac gets explicit unreachable/unsupported within 2 seconds and no fabricated echo reply. Record errno category, not destination history.

- [ ] **Step 4: Run ICMP acceptance**

```bash
: "${DROIDBRIDGE_B3_ICMP_HOST:?set DROIDBRIDGE_B3_ICMP_HOST to the controlled server}"
make b3-icmp
```

Expected: B3-07...B3-09 PASS according to actual device capability.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): validate B3 ICMP capability and replies"
```

---

### Task 5: LAN bypass exact-route security acceptance

**Files:**
- Create: `scripts/b3-lan-policy.sh`
- Create: `tools/lan_route_analyzer.py`
- Create: `tools/tests/test_lan_route_analyzer.py`
- Create: `docs/b3-lan-policy-test.md`

**Interfaces:**
- Consumes: current LAN test host and provider route snapshot.
- Produces: B3-10...B3-12 evidence.

- [ ] **Step 1: Write failing route-boundary tests**

```python
class LANRouteAnalyzerTests(unittest.TestCase):
    def test_only_displayed_subnet_is_direct(self):
        routes = parse_routes(route_fixture())
        assert_direct(routes, "192.168.50.20", expected=True)
        assert_direct(routes, "192.168.51.20", expected=False)
        assert_direct(routes, "8.8.8.8", expected=False)
        assert_no_default_bypass(routes)
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_lan_route_analyzer -v
```

Expected: FAIL because analyzer does not exist.

- [ ] **Step 3: Implement three-state LAN test**

1. denyAll: local test host unreachable through direct LAN.
2. currentLAN approved: displayed host reachable, route points to physical interface.
3. outside subnet/public/default: remains in utun and exits Android or is blocked.

Trigger a Wi-Fi subnet change and verify old bypass is removed before new approval. Test discovery toggle separately for mDNS exact addresses.

- [ ] **Step 4: Run LAN acceptance**

```bash
: "${DROIDBRIDGE_LAN_TEST_HOST:?set DROIDBRIDGE_LAN_TEST_HOST to an owned LAN host}"
make b3-lan-policy
```

Expected: B3-10...B3-12 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): verify exact B3 LAN bypass boundaries"
```

---

### Task 6: USB, sleep/wake, process, and cellular handover fault matrix

**Files:**
- Create: `scripts/b3-resilience.sh`
- Create: `tools/resilience_matrix.py`
- Create: `tools/tests/test_resilience_matrix.py`
- Create: `docs/b3-resilience-test.md`

**Interfaces:**
- Consumes: scripted/manual fault hooks and state/metrics stream.
- Produces: B3-13...B3-16 evidence.

- [ ] **Step 1: Write failing matrix completeness tests**

```python
class ResilienceMatrixTests(unittest.TestCase):
    def test_required_scenarios_exist(self):
        scenarios = {x.name for x in build_matrix()}
        self.assertEqual(scenarios, {
            "usb_5s", "usb_60s", "adb_offline", "android_process_restart",
            "mac_sleep_10m", "cellular_handover", "event_channel_loss",
        })
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_resilience_matrix -v
```

Expected: FAIL because matrix harness does not exist.

- [ ] **Step 3: Implement scenario assertions**

For every scenario assert: blocked state before retry, zero physical-interface leak, routes remain installed, old TCP flows close, new TCP succeeds after recovery, UDP/QUIC rebind result recorded, generation increases on cellular handover, and recovery time stays within spec. Sleep/wake uses a manual checkpoint if automated sleep permission is unavailable but still requires timestamped evidence.

- [ ] **Step 4: Run resilience matrix**

```bash
make b3-resilience
```

Expected: B3-13...B3-16 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): add B3 resilience fault matrix"
```

---

### Task 7: Performance, eight-hour soak, privacy, and stable packaging

**Files:**
- Create: `scripts/b3-performance.sh`
- Create: `scripts/b3-soak.sh`
- Create: `tools/b3_soak.py`
- Create: `tools/tests/test_b3_soak.py`
- Create: `scripts/package-b3.sh`
- Create: `docs/b3-release-manifest.json`
- Modify: `docs/operations.md`
- Modify: `docs/privacy.md`
- Modify: `docs/troubleshooting.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: all B1–B3 evidence and signed artifacts.
- Produces: B3-17...B3-20, `v0.3.0-b3`, same-commit `v1.0.0`.

- [ ] **Step 1: Write failing soak coverage test**

```python
class B3SoakTests(unittest.TestCase):
    def test_eight_hour_schedule_covers_families_and_faults(self):
        schedule = build_schedule(seconds=8 * 3600, seed=3)
        kinds = {e.kind for e in schedule}
        self.assertTrue({"tcp4", "tcp6", "udp4", "udp6", "quic4", "quic6",
                         "sleep_wake", "usb_fault", "cellular_handover", "lan_toggle"} <= kinds)
```

- [ ] **Step 2: Run and verify failure before implementation/evidence**

```bash
python3 -m unittest tools.tests.test_b3_soak -v
bash scripts/package-b3.sh
```

Expected: tests/package fail because schedule and full PASS manifest do not exist.

- [ ] **Step 3: Implement performance, soak, and deterministic package**

Performance measures IPv6 TCP at least 80% of B2 IPv4 baseline, IPv6 UDP at least 12 Mbps, DNS overhead median at most 30 ms, USB return recovery at most 10 seconds, wake recovery at most 15 seconds. Soak runs 8 hours across mixed families with scheduled faults and memory/flow/generation sampling. Privacy scan rejects payloads, DNS names, secrets, URLs, SNI, and subscriber identifiers. Package includes manifests, device matrix, source/submodule revisions, tool versions, signed artifacts, SBOM, and normalized timestamps.

- [ ] **Step 4: Run the complete release sequence**

```bash
make verify-b1-acceptance
make verify-b2-core verify-b2-acceptance
make verify-b3-core b3-preflight b3-dual-stack b3-icmp b3-lan-policy b3-resilience b3-performance b3-soak
python3 scripts/verify-b3-acceptance.py docs/b3-acceptance.json
bash scripts/package-b3.sh
git tag -s v0.3.0-b3 -m "DroidBridge B3 dual-stack release"
bash scripts/package-b3.sh --stable
git tag -s v1.0.0 -m "DroidBridge 1.0.0"
```

Expected: all 20 B3 criteria PASS; both tags point to the same commit; stable archive differs only in release metadata and has reproducible digest across two runs.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs CHANGELOG.md
git commit -m "release: prepare DroidBridge B3 and 1.0"
```
