# DroidBridge B2 Integration, Security, Performance, and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 실제 Mac/Android와 통제된 endpoint에서 B2 IPv4 UDP·QUIC 기능, fail-closed, 정책, 성능을 검증하고 `v0.2.0-b2` release artifact를 만든다.

**Architecture:** release harness는 UDP echo, sequence/jitter 측정, HTTP/3 endpoint를 통제된 서버에 제공한다. Mac 스크립트는 signed Packet Tunnel을 시작하고 evidence를 구조화된 JSON으로 수집하되 payload나 목적지 history를 보존하지 않는다.

**Tech Stack:** Python 3.11+, Docker, Caddy HTTP/3, iperf3, shell, signed macOS/Android builds

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b2-udp-quic-design.md`

## Global Constraints

- 모든 remote endpoint는 사용자가 제어하는 서버다.
- public third-party host를 부하·보안 시험 대상으로 사용하지 않는다.
- B1 acceptance를 같은 commit에서 먼저 재실행한다.
- evidence에는 aggregate latency/loss/bytes/status만 저장한다.
- 실패한 acceptance를 release manifest에서 숨기지 않는다.
- `v0.2.0-b2`는 14개 B2 acceptance 전체 PASS 후에만 생성한다.

## Review Focus

- 이동통신망 자체 손실과 DroidBridge queue drop을 구분해야 한다.
- HTTP/3 client가 실제 QUIC를 사용했는지 protocol negotiation evidence로 확인해야 한다.
- USB 분리 중 Mac Wi-Fi/Ethernet으로 UDP가 누출되지 않아야 한다.
- private destination test가 Android 내부망에 실제 packet을 보내기 전에 local policy에서 차단돼야 한다.
- soak 종료 후 relay listener, ADB forward, Packet Tunnel process가 정리돼야 한다.

---

### Task 1: B2 signed-build preflight and acceptance schema

**Files:**
- Create: `docs/b2-acceptance.json`
- Create: `scripts/b2-preflight.sh`
- Create: `scripts/verify-b2-acceptance.py`
- Create: `tools/tests/test_b2_acceptance_schema.py`
- Modify: `Makefile`

**Interfaces:**
- Consumes: B1 artifacts, signed B2 apps, attached device.
- Produces: machine-readable 14-item manifest and `make b2-preflight`.

- [ ] **Step 1: Write failing schema tests**

```python
class B2AcceptanceSchemaTests(unittest.TestCase):
    def test_exact_ids_and_no_skipped_status(self):
        manifest = load_manifest("docs/b2-acceptance.json")
        self.assertEqual([x["id"] for x in manifest["criteria"]], [f"B2-{i:02d}" for i in range(1, 15)])
        self.assertTrue(all(x["status"] in {"PASS", "FAIL", "NOT_RUN"} for x in manifest["criteria"]))
        self.assertNotIn("SKIP", json.dumps(manifest))
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b2_acceptance_schema -v
```

Expected: FAIL because schema and verifier do not exist.

- [ ] **Step 3: Implement preflight and verifier**

Preflight checks Apple Silicon, macOS 14+, codesigned Network Extension entitlement, one authorized Android, relay app version, B1 manifest PASS, ports 27183/27184 free or owned, cellular available, controlled server variables set, and `curl --version` advertising HTTP3 support. Verifier exits non-zero unless all 14 statuses are PASS and evidence files have SHA-256 entries.

- [ ] **Step 4: Run schema and preflight**

```bash
python3 -m unittest tools.tests.test_b2_acceptance_schema -v
make b2-preflight
```

Expected: schema PASS; preflight either PASS or a specific missing-environment error.

- [ ] **Step 5: Commit**

```bash
git add docs scripts tools/tests Makefile
git commit -m "test(release): define B2 acceptance gate"
```

---

### Task 2: Controlled UDP and HTTP/3 benchmark service

**Files:**
- Create: `tools/b2-server/docker-compose.yml`
- Create: `tools/b2-server/udp_echo.py`
- Create: `tools/b2-server/udp_sequence.py`
- Create: `tools/b2-server/Caddyfile`
- Create: `tools/b2-server/site/10m.bin.sha256`
- Create: `tools/tests/test_b2_udp_protocol.py`
- Create: `docs/b2-controlled-server.md`

**Interfaces:**
- Consumes: a server owned by the user with UDP 4433/4434 and TCP+UDP 443.
- Produces: echo, timestamp/sequence service, HTTP/3 10 MiB object.

- [ ] **Step 1: Write failing UDP protocol tests**

```python
class SequenceProtocolTests(unittest.TestCase):
    def test_response_preserves_sequence_and_payload_length(self):
        request = encode_request(sequence=7, sent_ns=123, payload=b"x" * 1200)
        response = handle_request(request, received_ns=456)
        decoded = decode_response(response)
        self.assertEqual(decoded.sequence, 7)
        self.assertEqual(decoded.payload_length, 1200)
        self.assertEqual(decoded.received_ns, 456)
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b2_udp_protocol -v
```

Expected: FAIL because server protocol does not exist.

- [ ] **Step 3: Implement bounded services**

UDP services accept at most 1,232 bytes, never write payload to disk, and rate-limit each source to 2,000 datagrams/second. `udp_echo.py` returns bytes unchanged. `udp_sequence.py` returns fixed header fields only and random padding of the same length. Caddy serves a deterministic 10 MiB object and advertises HTTP/3.

- [ ] **Step 4: Run local service tests**

```bash
python3 -m unittest tools.tests.test_b2_udp_protocol -v
docker compose -f tools/b2-server/docker-compose.yml config
docker compose -f tools/b2-server/docker-compose.yml up -d
```

Expected: tests PASS and services become healthy.

- [ ] **Step 5: Commit**

```bash
git add tools/b2-server tools/tests docs/b2-controlled-server.md
git commit -m "test(release): add controlled B2 UDP and HTTP3 server"
```

---

### Task 3: End-to-end UDP and QUIC functional acceptance

**Files:**
- Create: `scripts/b2-functional.sh`
- Create: `tools/b2_udp_probe.py`
- Create: `tools/tests/test_b2_udp_probe.py`
- Create: `docs/b2-functional-test.md`

**Interfaces:**
- Consumes: connected B2 tunnel and controlled server.
- Produces: evidence for B2-01...B2-06 and B1 regression reference.

- [ ] **Step 1: Write failing probe tests**

```python
class UDPProbeTests(unittest.TestCase):
    def test_summary_reports_loss_and_never_payload(self):
        summary = summarize(sent=[1,2,3], received=[1,3], latencies_ms=[10.0, 12.0])
        self.assertEqual(summary["loss_percent"], 100 / 3)
        self.assertNotIn("payload", json.dumps(summary).lower())
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b2_udp_probe -v
```

Expected: FAIL because probe does not exist.

- [ ] **Step 3: Implement functional script**

The script performs:

```text
1. run B1 functional regression
2. 1-byte UDP echo
3. 1,200-byte UDP echo
4. 1,232-byte UDP echo
5. verify 1,233-byte local drop counter increments
6. 1,000 sequence packets at 100 pps
7. curl --http3-only controlled 10 MiB object
8. verify downloaded SHA-256
9. capture Android cellular byte counter delta
```

Fail if curl reports HTTP/2 or HTTP/1.1. Evidence stores negotiated protocol, object digest, counts, loss, p50/p95 latency, and metrics deltas.

- [ ] **Step 4: Run functional acceptance**

```bash
: "${DROIDBRIDGE_B2_SERVER:?set DROIDBRIDGE_B2_SERVER to the controlled server}"
make b2-functional
```

Expected: criteria B2-01...B2-06 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): add B2 UDP and QUIC functional acceptance"
```

---

### Task 4: Fail-closed, policy, and malformed-frame acceptance

**Files:**
- Create: `scripts/b2-security.sh`
- Create: `tools/dbp_udp_negative_suite.py`
- Create: `tools/tests/test_dbp_udp_negative_suite.py`
- Create: `docs/b2-security-test.md`

**Interfaces:**
- Consumes: debug relay and Packet Tunnel metrics.
- Produces: B2-07...B2-11 evidence.

- [ ] **Step 1: Write failing negative-suite tests**

```python
class NegativeCaseTests(unittest.TestCase):
    def test_cases_cover_boundaries(self):
        names = {case.name for case in build_cases()}
        self.assertTrue({"length_1233", "reserved_nonzero", "flag_unknown",
                         "truncated_payload", "private_destination", "replayed_hello"} <= names)
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_dbp_udp_negative_suite -v
```

Expected: FAIL because suite does not exist.

- [ ] **Step 3: Implement controlled fault tests**

The script verifies private/link-local/multicast destinations are rejected before socket creation, malformed frames close only their session, 256 UDP hard limit, USB detach leak capture for IPv4 UDP, cellular loss no-fallback, and reconnect does not silently resume old flow. Packet capture is performed only on the user's Mac interfaces and stores header counts, not payload bytes.

- [ ] **Step 4: Run security acceptance**

```bash
make b2-security
```

Expected: B2-07...B2-11 PASS; no host interface UDP egress during blocked period.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): add B2 fail-closed and protocol security suite"
```

---

### Task 5: UDP performance, 100-flow concurrency, and two-hour soak

**Files:**
- Create: `scripts/b2-performance.sh`
- Create: `scripts/b2-soak.sh`
- Create: `tools/b2_mixed_soak.py`
- Create: `tools/tests/test_b2_mixed_soak.py`
- Create: `docs/b2-performance.md`

**Interfaces:**
- Consumes: controlled server and metrics stream.
- Produces: B2-12...B2-13 evidence.

- [ ] **Step 1: Write failing scheduler tests**

```python
class MixedSoakTests(unittest.TestCase):
    def test_schedule_contains_tcp_udp_quic_and_fault_windows(self):
        events = build_schedule(duration_seconds=7200, seed=7)
        kinds = {event.kind for event in events}
        self.assertTrue({"tcp", "udp", "quic", "idle", "usb_fault"} <= kinds)
        self.assertTrue(all(0 <= e.at_seconds <= 7200 for e in events))
```

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_b2_mixed_soak -v
```

Expected: FAIL because scheduler does not exist.

- [ ] **Step 3: Implement reproducible benchmark and soak**

Performance runs 100 concurrent UDP flows for 10 minutes, `iperf3 -u` target 20 Mbps and accepts at least 15 Mbps, and computes jitter delta against direct Android baseline. Soak runs 2 hours with 40 TCP, 40 UDP, periodic HTTP/3 requests, one controlled 10-second USB disconnect, and memory samples every minute. Fail on crash, queue drop above 0.5%, or stable-window RSS growth above 20 MiB.

- [ ] **Step 4: Run performance and soak**

```bash
make b2-performance
make b2-soak
```

Expected: B2-12 and B2-13 PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts tools docs
git commit -m "test(release): add B2 performance and soak gates"
```

---

### Task 6: Privacy audit, packaging, and v0.2.0-b2 release gate

**Files:**
- Modify: `docs/privacy.md`
- Modify: `docs/operations.md`
- Modify: `docs/troubleshooting.md`
- Create: `scripts/package-b2.sh`
- Create: `docs/b2-release-manifest.json`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: all B2 evidence and signed binaries.
- Produces: reproducible B2 archive and release manifest.

- [ ] **Step 1: Write a failing privacy scan command**

```bash
set -euo pipefail
! grep -RIE 'payload_hex|Authorization:|Cookie:|example\.com|93\.184\.216\.34' evidence/b2
python3 scripts/verify-b2-acceptance.py docs/b2-acceptance.json
```

- [ ] **Step 2: Run and verify failure before final evidence**

```bash
bash scripts/package-b2.sh
```

Expected: FAIL until all criteria are PASS and required evidence exists.

- [ ] **Step 3: Implement deterministic packaging**

Package signed HostApp, PacketTunnel extension, Android APK, exact source commit, submodule revisions, build tool versions, B1 regression manifest, B2 acceptance manifest, privacy scan result, and SHA-256 list. Normalize archive timestamps with `SOURCE_DATE_EPOCH` and sort entries.

- [ ] **Step 4: Run complete gate and create tag**

```bash
make verify-b1-acceptance
make verify-b2-core
make b2-preflight b2-functional b2-security b2-performance b2-soak
bash scripts/package-b2.sh
git tag -s v0.2.0-b2 -m "DroidBridge B2 IPv4 UDP and QUIC"
```

Expected: all gates PASS and archive digest is stable across two packaging runs.

- [ ] **Step 5: Commit**

```bash
git add docs scripts CHANGELOG.md
git commit -m "release: prepare DroidBridge B2"
```
