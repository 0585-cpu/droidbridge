# DroidBridge B3 Dual-Stack Protocol and Packet Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DBP/1.2 capability·event·IPv6·ICMP codec와 C dual-stack TCP/UDP/ICMP packet core를 완성한다.

**Architecture:** 기존 IPv4 전용 tuple을 family+16-byte canonical address 모델로 일반화한다. lwIP는 TCP4/TCP6를 처리하고, custom UDP engine은 UDP4/UDP6를 처리하며, ICMP engine은 echo request mapping과 local error synthesis만 담당한다.

**Tech Stack:** C17, lwIP dual-stack, CMake/CTest, libFuzzer, Python canonical fixtures

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b3-dual-stack-resilience-design.md`

## Global Constraints

- IPv4 representation은 first 4 bytes + 12 zero bytes이며 IPv4-mapped IPv6로 저장하지 않는다.
- IPv6 extension chain은 최대 4 headers, 총 256 bytes다.
- non-atomic IPv6 fragment는 drop한다.
- UDP6 checksum 0은 invalid다.
- virtual IPv6 network는 `fd7d:6272:6964::/126`이다.
- MTU는 1,280, UDP payload maximum은 1,232다.
- destination policy는 IPv4/IPv6/NAT64 embedded address에 모두 적용한다.
- arbitrary ICMP forwarding은 구현하지 않는다.
- B1/B2 vectors와 ABI behavior를 유지한다.

## Review Focus

- IPv6 extension header length overflow와 circular/overlong chain이 bounded reject로 끝나야 한다.
- IPv4와 IPv6 동일 byte prefix가 flow hash collision으로 합쳐지지 않아야 한다.
- NAT64 prefix 길이 32...96 처리에서 embedded IPv4 bit extraction이 정확해야 한다.
- DNSSEC-signed response를 수정해 유효하지 않은 응답을 전달하지 않아야 한다.
- ICMP request timeout과 late response가 request-id 재사용에 잘못 매핑되지 않아야 한다.

---

### Task 1: DBP/1.2 capability, IPv6, event, and ICMP fixtures

**Files:**
- Modify: `protocol/dbp-v1.md`
- Modify: `tools/generate_protocol_vectors.py`
- Modify: `protocol/test-vectors/dbp-v1.json`
- Modify: `tools/tests/test_protocol_vectors.py`
- Create: `protocol/test-vectors/dbp-v1-b2.sha256`

**Interfaces:**
- Consumes: B1/B2 frozen canonical subsets.
- Produces: address type 2, health payload v2, event messages 0x50...0x53, ICMP messages 0x60...0x62.

- [ ] **Step 1: Write failing compatibility and v2 vector tests**

```python
class DBP12VectorTests(unittest.TestCase):
    def test_b2_subset_digest_is_frozen(self):
        self.assertEqual(
            hashlib.sha256(canonical_b2_subset_bytes(load_vectors())).hexdigest(),
            Path("protocol/test-vectors/dbp-v1-b2.sha256").read_text().strip(),
        )

    def test_open_tcp_ipv6_vector(self):
        vector = find_vector("open_tcp_ipv6_443")
        payload = bytes.fromhex(vector["payload_hex"])
        self.assertEqual(payload[0], 2)
        self.assertEqual(int.from_bytes(payload[1:3], "big"), 443)
        self.assertEqual(payload[3], 16)
        self.assertEqual(ipaddress.IPv6Address(payload[4:20]), ipaddress.IPv6Address("2606:4700:4700::1111"))

    def test_health_v2_has_generation_and_capabilities(self):
        health = decode_health_v2(find_vector("health_dual_stack")["payload_hex"])
        self.assertEqual(health.version, 2)
        self.assertTrue(health.capabilities & CAP_TCP6)
        self.assertEqual(health.network_generation, 9)
```

Add vectors for NAT64 prefix /96 and /64, event network change, ICMP4/ICMP6 echo, unsupported family, payload 1200/1201, and invalid capability reserved bits.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_protocol_vectors -v
```

Expected: FAIL because DBP/1.2 vectors and B2 digest file do not exist.

- [ ] **Step 3: Extend the canonical generator**

Define exact health v2 payload:

```text
1 byte   payload version = 2
1 byte   cellular state
2 bytes  active TCP
2 bytes  active UDP
2 bytes  max TCP
2 bytes  max UDP
8 bytes  capability bitset
8 bytes  network generation
1 byte   NAT64 prefix length, 0 or 32...96
16 bytes NAT64 prefix bytes, zero when absent
1 byte   carrier UTF-8 length, 0...63
N bytes  carrier
```

Encode event and ICMP payloads exactly as specified. Preserve B1/B2 vectors and regenerate deterministically.

- [ ] **Step 4: Regenerate twice and run tests**

```bash
python3 tools/generate_protocol_vectors.py --output protocol/test-vectors/dbp-v1.json
python3 -m unittest tools.tests.test_protocol_vectors -v
cp protocol/test-vectors/dbp-v1.json /tmp/dbp-v1.json
python3 tools/generate_protocol_vectors.py --output protocol/test-vectors/dbp-v1.json
cmp /tmp/dbp-v1.json protocol/test-vectors/dbp-v1.json
```

Expected: all PASS and no second-run diff.

- [ ] **Step 5: Commit**

```bash
git add protocol tools
git commit -m "feat(protocol): define DBP dual-stack extension"
```

---

### Task 2: Canonical IP address model and IPv6 parser/checksums

**Files:**
- Create: `core/include/droidbridge_ip.h`
- Create: `core/src/ip_address.c`
- Create: `core/src/ipv6_packet.c`
- Modify: `core/src/checksum.c`
- Create: `core/tests/test_ip_address.c`
- Create: `core/tests/test_ipv6_packet.c`
- Modify: `core/tests/packet_builder.h`
- Modify: `core/tests/packet_builder.c`
- Modify: `core/CMakeLists.txt`

**Interfaces:**
- Consumes: raw IPv4/IPv6 packet bytes.
- Produces: `db_ip_address_t`, `db_ipv6_parse`, IPv6 pseudo-header checksum APIs.

- [ ] **Step 1: Write failing family and extension tests**

```c
static void test_ipv4_and_ipv6_never_compare_equal(void) {
    db_ip_address_t v4 = db_ip_v4(0x01020304);
    uint8_t bytes[16] = {1,2,3,4};
    db_ip_address_t v6 = db_ip_v6(bytes);
    ASSERT_FALSE(db_ip_equal(&v4, &v6));
    ASSERT_NE_U64(db_ip_hash(&v4, 7), db_ip_hash(&v6, 7));
}

static void test_ipv6_parser_rejects_fifth_extension_header(void) {
    uint8_t packet[512];
    size_t length = build_ipv6_with_destination_options(packet, sizeof(packet), 5);
    db_ipv6_packet_t parsed = {0};
    ASSERT_EQ_INT(DB_IPV6_TOO_MANY_EXTENSIONS, db_ipv6_parse(packet, length, &parsed));
}

static void test_udp6_zero_checksum_is_invalid(void) {
    uint8_t packet[256];
    size_t length = build_ipv6_udp(packet, sizeof(packet), true, 0);
    ASSERT_EQ_INT(DB_IPV6_BAD_CHECKSUM, db_ipv6_parse(packet, length, &(db_ipv6_packet_t){0}));
}
```

Add truncated header, payload length mismatch, Routing Header type 0, atomic fragment accepted, M flag rejected, odd-length payload, ICMPv6 checksum, and extension total 257 tests.

- [ ] **Step 2: Run and verify failure**

```bash
cmake -S core -B build/core-b3 -DCMAKE_BUILD_TYPE=Debug -DDB_ENABLE_SANITIZERS=ON
cmake --build build/core-b3 --parallel
ctest --test-dir build/core-b3 -R 'ip_address|ipv6_packet' --output-on-failure
```

Expected: compile failure because IP/IPv6 APIs do not exist.

- [ ] **Step 3: Implement bounded parsing**

```c
typedef enum { DB_AF_NONE = 0, DB_AF_IPV4 = 4, DB_AF_IPV6 = 6 } db_address_family_t;
typedef struct { uint8_t family; uint8_t bytes[16]; } db_ip_address_t;
```

`db_ipv6_parse` walks extension headers with checked addition, stores final next-header and transport offset, and never follows Routing Header type 0. Checksum helpers accept explicit source/destination addresses, next header, and payload length.

- [ ] **Step 4: Run tests and sanitizers**

```bash
cmake --build build/core-b3 --parallel
ctest --test-dir build/core-b3 -R 'ip_address|ipv6_packet' --output-on-failure
```

Expected: PASS without sanitizer findings.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): add bounded IPv6 parsing and checksums"
```

---

### Task 3: IPv6 destination policy and NAT64 embedded IPv4 validation

**Files:**
- Modify: `core/include/droidbridge_policy.h`
- Modify: `core/src/destination_policy.c`
- Create: `core/src/nat64_prefix.c`
- Modify: `protocol/test-vectors/destination-policy.json`
- Modify: `core/tests/test_destination_policy.c`
- Create: `core/tests/test_nat64_prefix.c`

**Interfaces:**
- Consumes: canonical `db_ip_address_t`, optional NAT64 prefix length/address.
- Produces: `db_policy_evaluate_ip`, `db_nat64_extract_ipv4`.

- [ ] **Step 1: Write failing boundary tests**

```c
static void test_ipv6_global_is_allowed_and_ula_is_denied(void) {
    ASSERT_EQ_INT(DB_POLICY_ALLOW, policy("2606:4700:4700::1111", NULL));
    ASSERT_EQ_INT(DB_POLICY_DENY_PRIVATE, policy("fd00::1", NULL));
    ASSERT_EQ_INT(DB_POLICY_DENY_LINK_LOCAL, policy("fe80::1", NULL));
}

static void test_nat64_private_embedded_ipv4_is_denied(void) {
    db_nat64_prefix_t prefix = nat64_prefix("64:ff9b::", 96);
    ASSERT_EQ_INT(DB_POLICY_DENY_PRIVATE, policy("64:ff9b::c0a8:0101", &prefix));
    ASSERT_EQ_INT(DB_POLICY_ALLOW, policy("64:ff9b::5db8:d822", &prefix));
}
```

Add prefix lengths 32,40,48,56,64,96, invalid 31/97, documentation/benchmark/multicast, IPv4-mapped, and non-matching prefix tests.

- [ ] **Step 2: Run and verify failure**

```bash
ctest --test-dir build/core-b3 -R 'destination_policy|nat64_prefix' --output-on-failure
```

Expected: tests fail because IPv6/NAT64 policy is absent.

- [ ] **Step 3: Implement exact CIDR tables and RFC 6052 extraction**

Use a table of prefix bytes and lengths from the B3 spec. `db_nat64_extract_ipv4` supports only RFC 6052 allowed prefix lengths and returns false for suffix/u-octet violations. If extraction succeeds, run the existing IPv4 policy on the embedded address before allowing the IPv6 destination.

- [ ] **Step 4: Run policy tests and fixture parity**

```bash
ctest --test-dir build/core-b3 -R 'destination_policy|nat64_prefix' --output-on-failure
python3 -m unittest tools.tests.test_protocol_vectors -v
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core protocol/test-vectors/destination-policy.json
git commit -m "feat(core): enforce IPv6 and NAT64 destination policy"
```

---

### Task 4: Dual-stack lwIP adapter

**Files:**
- Modify: `core/ports/lwipopts.h`
- Modify: `core/src/lwip_adapter.c`
- Modify: `core/include/droidbridge_core.h`
- Modify: `core/tests/test_lwip_adapter.c`
- Create: `core/tests/test_lwip_ipv6_tcp.c`

**Interfaces:**
- Consumes: IPv4/IPv6 packets and monotonic timers.
- Produces: TCP4/TCP6 stream callbacks with canonical flow keys.

- [ ] **Step 1: Write failing dual-stack netif tests**

```c
static void test_lwip_has_virtual_ipv6_gateway(void) {
    db_lwip_context_t *ctx = make_lwip();
    ASSERT_IPV6_EQ("fd7d:6272:6964::1", db_lwip_ipv6_address(ctx));
    ASSERT_EQ_INT(126, db_lwip_ipv6_prefix_length(ctx));
    db_lwip_shutdown(ctx);
}

static void test_ipv6_syn_creates_tcp6_flow(void) {
    db_lwip_context_t *ctx = make_lwip_with_flow_recorder();
    inject_ipv6_syn(ctx, "fd7d:6272:6964::2", 50000, "2606:4700:4700::1111", 443);
    ASSERT_EQ_INT(DB_AF_IPV6, recorder.last_flow.source.family);
    ASSERT_EQ_INT(443, recorder.last_flow.destination_port);
}
```

- [ ] **Step 2: Run and verify failure**

```bash
ctest --test-dir build/core-b3 -R 'lwip_adapter|lwip_ipv6_tcp' --output-on-failure
```

Expected: FAIL because lwIP IPv6 is disabled.

- [ ] **Step 3: Enable bounded lwIP IPv6 TCP**

Set:

```c
#define LWIP_IPV6 1
#define LWIP_IPV6_SCOPES 1
#define LWIP_IPV6_AUTOCONFIG 0
#define LWIP_ICMP6 1
#define LWIP_IPV6_MLD 0
```

The virtual interface receives a static /126 address. Its `output_ip6` callback emits IP packets directly to the Packet Tunnel path, so no link-layer neighbor cache is exposed to macOS. lwIP ICMPv6 remains enabled for internal TCP error handling, while Router Solicitation, Neighbor Discovery, and MLD packets are not relayed as user traffic. Generalize rewrite tuples to `db_ip_address_t`; preserve B1 IPv4 behavior.

- [ ] **Step 4: Run complete lwIP/core tests**

```bash
cmake --build build/core-b3 --parallel
ctest --test-dir build/core-b3 --output-on-failure
```

Expected: all B1/B2/B3 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): enable dual-stack lwIP TCP"
```

---

### Task 5: Generalize flow tables and UDP engine to IPv6

**Files:**
- Modify: `core/src/flow_table.c`
- Modify: `core/src/udp_flow_table.c`
- Modify: `core/src/udp_engine.c`
- Modify: `core/src/packet_engine.c`
- Modify: `core/include/droidbridge_udp_flow.h`
- Create: `core/tests/test_packet_engine_ipv6.c`
- Modify: `core/tests/test_128_flows.c`

**Interfaces:**
- Consumes: canonical `db_flow_key_t` and IPv6 packet views.
- Produces: TCP6 and UDP6 open/data/close callbacks; response packet synthesis.

- [ ] **Step 1: Write failing mixed-family tests**

```c
static void test_same_ports_ipv4_and_ipv6_are_distinct_flows(void) {
    db_engine_t *engine = make_engine();
    inject_tcp4_syn(engine, 50000, "93.184.216.34", 443);
    inject_tcp6_syn(engine, 50000, "2606:4700:4700::1111", 443);
    ASSERT_EQ_SIZE(2, db_engine_metrics(engine).active_tcp);
}

static void test_udp6_response_has_mandatory_checksum(void) {
    db_engine_t *engine = open_udp6_flow();
    db_engine_udp_deliver(engine, last_flow_id(), (uint8_t *)"abc", 3, 100);
    const packet_t packet = recorder_last_packet();
    ASSERT_EQ_INT(6, packet_ip_version(packet));
    ASSERT_NE_INT(0, packet_udp_checksum(packet));
    ASSERT_TRUE(validate_udp6_checksum(packet));
}
```

Add 128 mixed TCP4/TCP6, 128 mixed UDP4/UDP6, atomic fragment, blocked ULA, and IPv6 flow timeout tests.

- [ ] **Step 2: Run and verify failure**

```bash
ctest --test-dir build/core-b3 -R 'packet_engine_ipv6|128_flows' --output-on-failure
```

Expected: FAIL because engine remains IPv4-only.

- [ ] **Step 3: Generalize keys and packet dispatch**

Replace IPv4-specific key structs in public ABI with `db_flow_key_t`; keep compatibility wrapper constructors for B1/B2 tests. Dispatch packet version 4/6 before transport. UDP6 response builder uses flow addresses reversed and computes mandatory checksum. Limits remain per protocol across both families, not per family.

- [ ] **Step 4: Run all core tests**

```bash
ctest --test-dir build/core-b3 --output-on-failure
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): support IPv6 TCP and UDP flows"
```

---

### Task 6: Dual-stack DNS policy and SVCB/HTTPS ipv6hint handling

**Files:**
- Modify: `core/src/dns_packet.c`
- Modify: `core/src/dns_bridge.c`
- Create: `core/src/dns_policy.c`
- Create: `core/tests/test_dns_dual_stack.c`
- Create: `core/fuzz/fuzz_dns_policy.c`

**Interfaces:**
- Consumes: DNS wire response, `ipv6Available`, destination policy.
- Produces: filtered DNS response or explicit SERVFAIL decision.

- [ ] **Step 1: Write failing response transformation tests**

```c
static void test_aaaa_becomes_nodata_when_ipv6_unavailable(void) {
    dns_message_t input = fixture_aaaa_response("example.test", "2606:4700::1");
    dns_transform_result_t result = db_dns_apply_policy(&input, false, NULL);
    ASSERT_EQ_INT(DB_DNS_TRANSFORMED, result.status);
    ASSERT_EQ_INT(0, result.message.answer_count);
    ASSERT_EQ_INT(DNS_RCODE_NOERROR, result.message.rcode);
}

static void test_signed_response_needing_change_becomes_servfail(void) {
    dns_message_t input = fixture_dnssec_aaaa_response();
    dns_transform_result_t result = db_dns_apply_policy(&input, false, NULL);
    ASSERT_EQ_INT(DB_DNS_SERVFAIL, result.status);
}
```

Add A retained, blocked AAAA removed, SVCB ipv6hint stripped, ipv4hint retained, malformed parameter lengths, compression loops, and response size growth tests.

- [ ] **Step 2: Run and verify failure**

```bash
ctest --test-dir build/core-b3 -R dns_dual_stack --output-on-failure
```

Expected: FAIL because dual-stack DNS policy does not exist.

- [ ] **Step 3: Implement conservative DNS transformation**

Parse question/answer/authority/additional with existing bounded compression handling. Only modify AAAA and SVCB/HTTPS ipv6hint. If RRSIG covers a record that would be modified, return a freshly constructed SERVFAIL retaining transaction ID and question. Never increase response above 4,096 bytes.

- [ ] **Step 4: Run tests and fuzz**

```bash
ctest --test-dir build/core-b3 -R dns_dual_stack --output-on-failure
./build/core-b3/fuzz_dns_policy -runs=50000
```

Expected: PASS and no crash.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): apply dual-stack DNS policy"
```

---

### Task 7: ICMP echo mapping and local error synthesis

**Files:**
- Create: `core/include/droidbridge_icmp.h`
- Create: `core/src/icmp_engine.c`
- Create: `core/src/icmp_packet.c`
- Create: `core/tests/test_icmp_engine.c`
- Create: `core/tests/test_icmp_packet.c`
- Modify: `core/src/packet_engine.c`

**Interfaces:**
- Consumes: ICMPv4 Echo Request, ICMPv6 Echo Request, relay response/error.
- Produces: `on_icmp_echo`, `db_engine_icmp_reply`, `db_engine_icmp_error`, local unreachable/packet-too-big packets.

- [ ] **Step 1: Write failing mapping and timeout tests**

```c
static void test_reply_restores_original_identifier_and_sequence(void) {
    db_engine_t *engine = make_engine_with_icmp_recorder();
    inject_icmp4_echo(engine, "198.18.0.2", "1.1.1.1", 0x1234, 9, "abc");
    uint32_t request_id = recorder.last_request_id;
    db_engine_icmp_reply(engine, request_id, 54, (uint8_t *)"abc", 3, 1000);
    packet_t reply = recorder_last_packet();
    ASSERT_EQ_INT(0x1234, icmp_identifier(reply));
    ASSERT_EQ_INT(9, icmp_sequence(reply));
}

static void test_late_reply_after_timeout_is_ignored(void) {
    db_engine_t *engine = make_engine();
    uint32_t request_id = inject_and_get_request_id(engine);
    db_engine_poll(engine, 5001);
    ASSERT_FALSE(db_engine_icmp_reply(engine, request_id, 64, NULL, 0, 6000));
}
```

Add IPv6 echo, payload 1200/1201, unsupported capability local unreachable, request ID wrap, duplicate reply, and UDP `ECONNREFUSED` port unreachable synthesis tests.

- [ ] **Step 2: Run and verify failure**

```bash
ctest --test-dir build/core-b3 -R 'icmp_engine|icmp_packet' --output-on-failure
```

Expected: FAIL because ICMP engine is absent.

- [ ] **Step 3: Implement bounded request map**

Allow at most 64 outstanding echo requests with 5-second timeout. Generate non-zero 32-bit request IDs and skip active IDs on wrap. Store family, original source/destination, identifier, sequence, and payload digest/length; retain payload only up to 1,200 bytes until reply. Unsupported capability immediately synthesizes destination unreachable/admin prohibited rather than silently leaking.

- [ ] **Step 4: Run ICMP and full core tests**

```bash
ctest --test-dir build/core-b3 -R 'icmp_engine|icmp_packet' --output-on-failure
ctest --test-dir build/core-b3 --output-on-failure
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): add capability-based ICMP echo mapping"
```

---

### Task 8: B3 dual-stack fuzz and core verification gate

**Files:**
- Create: `core/fuzz/fuzz_ipv6_packet.c`
- Create: `core/fuzz/fuzz_nat64_prefix.c`
- Create: `core/fuzz/fuzz_icmp_packet.c`
- Create: `scripts/verify-b3-core.sh`
- Modify: `.github/workflows/foundation.yml`
- Modify: `Makefile`

**Interfaces:**
- Consumes: all core B1–B3 tests and fixtures.
- Produces: `make verify-b3-core`.

- [ ] **Step 1: Write the failing gate script**

```bash
#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest tools.tests.test_protocol_vectors -v
cmake -S core -B build/core-b3-gate -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDB_ENABLE_SANITIZERS=ON
cmake --build build/core-b3-gate --parallel
ctest --test-dir build/core-b3-gate --output-on-failure
for target in fuzz_ipv6_packet fuzz_nat64_prefix fuzz_icmp_packet fuzz_dns_policy; do
  ./build/core-b3-gate/$target -runs=50000
 done
```

- [ ] **Step 2: Run and verify failure**

```bash
make verify-b3-core
```

Expected: FAIL because gate and fuzz targets do not exist.

- [ ] **Step 3: Implement fuzz harnesses and CI matrix**

Fuzzers use deterministic callbacks and no network/filesystem. CI runs arm64 macOS unit tests plus Linux sanitizer/fuzzer build. Nightly runs one million iterations per B3 target and stores only crash artifacts.

- [ ] **Step 4: Run the gate twice**

```bash
make verify-b3-core
make verify-b3-core
```

Expected: both PASS and no generated file diff.

- [ ] **Step 5: Commit**

```bash
git add core scripts .github Makefile
git commit -m "test(core): add B3 dual-stack verification gate"
```
