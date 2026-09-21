# DroidBridge B2 Protocol and IPv4 UDP Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** B1과 wire-compatible한 DBP/1.1 UDP 확장, canonical fixture, C IPv4 UDP parser/checksum/flow engine을 완성한다.

**Architecture:** DBP base header와 인증은 유지하고 `OPEN_UDP` 이후 compact datagram frame으로 전환한다. C core는 IPv4/UDP packet을 직접 검증하고 5-tuple flow를 관리하며, Swift가 relay lifecycle을 소유할 수 있도록 callback 기반 ABI를 제공한다.

**Tech Stack:** C17, CMake, CTest, libFuzzer, Python 3.11+, canonical JSON fixtures

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-b2-udp-quic-design.md`

## Global Constraints

- DBP common header는 64 bytes, magic은 `DBP1`을 유지한다.
- B1 message type과 fixture는 byte-for-byte 변경하지 않는다.
- B2 UDP payload maximum은 1,232 bytes다.
- `OPEN_UDP`는 IPv4 literal만 허용한다.
- IPv4 fragment는 재조립하지 않는다.
- UDP checksum 0은 IPv4에서 허용하고 non-zero checksum은 반드시 검증한다.
- flow default limit 128, hard limit 256, TCP+UDP hard limit 512다.
- payload와 destination은 test fixture 외 로그에 기록하지 않는다.

## Review Focus

- B1 fixture가 B2 generator 변경 후에도 동일 SHA-256을 유지해야 한다.
- UDP length와 IPv4 total length가 불일치할 때 out-of-bounds read 없이 거부해야 한다.
- odd-length UDP payload checksum과 wire checksum `0xffff` 변환이 정확해야 한다.
- 같은 source port를 여러 destination이 공유해도 flow collision이 없어야 한다.
- timeout sweep와 explicit close가 경쟁해도 callback이 두 번 호출되지 않아야 한다.

---

### Task 1: Canonical DBP/1.1 UDP specification and fixtures

**Files:**
- Modify: `protocol/dbp-v1.md`
- Modify: `tools/generate_protocol_vectors.py`
- Modify: `protocol/test-vectors/dbp-v1.json`
- Modify: `tools/tests/test_protocol_vectors.py`
- Create: `protocol/test-vectors/dbp-v1-b1.sha256`

**Interfaces:**
- Consumes: B1 `encode_header()`와 HMAC fixture generator.
- Produces: message constants `OPEN_UDP=0x40`, `OPEN_UDP_OK=0x41`, `OPEN_UDP_ERROR=0x42`, `UDP_CLOSE=0x43`; canonical `open_udp`와 `udp_frame` vectors.

- [ ] **Step 1: Write failing compatibility and UDP vector tests**

```python
class ProtocolVectorTests(unittest.TestCase):
    def test_b1_vectors_keep_frozen_digest(self):
        current = canonical_b1_subset_bytes(load_vectors())
        self.assertEqual(
            hashlib.sha256(current).hexdigest(),
            Path("protocol/test-vectors/dbp-v1-b1.sha256").read_text().strip(),
        )

    def test_open_udp_vector_is_exact(self):
        vector = find_vector("open_udp_ipv4_quic")
        self.assertEqual(vector["message_type"], 0x40)
        self.assertEqual(bytes.fromhex(vector["payload_hex"]),
                         b"\x01\x01\xbb\x04\x5d\xb8\xd8\x22\x00\x78")

    def test_udp_frame_maximum_is_1232(self):
        self.assertEqual(find_limit("udp_payload_max"), 1232)
```

The IPv4 fixture is `93.184.216.34:443` with idle timeout 120 seconds. Add vectors for zero port, address length 3/5, timeout 29/301, non-zero reserved byte, payload 1,232 and 1,233.

- [ ] **Step 2: Run and verify failure**

```bash
python3 -m unittest tools.tests.test_protocol_vectors -v
```

Expected: FAIL because B2 constants, digest freeze file, and UDP vectors do not exist.

- [ ] **Step 3: Extend the generator without rewriting B1 entries**

Add these exact helpers:

```python
def encode_open_udp_ipv4(address: str, port: int, idle_seconds: int) -> bytes:
    packed = ipaddress.IPv4Address(address).packed
    if not 1 <= port <= 65535:
        raise ValueError("port")
    if not 30 <= idle_seconds <= 300:
        raise ValueError("idle_seconds")
    return b"\x01" + port.to_bytes(2, "big") + b"\x04" + packed + idle_seconds.to_bytes(2, "big")


def encode_udp_frame(payload: bytes, flags: int, sequence: int) -> bytes:
    if len(payload) > 1232 or flags & ~0x03:
        raise ValueError("udp frame")
    return len(payload).to_bytes(2, "big") + bytes([flags, 0]) + sequence.to_bytes(4, "big") + payload
```

Document datagram mode transition, limits, error codes 10...14, sequence semantics, and the requirement that reserved is zero. Generate the B1 digest from the pre-change canonical subset once and commit the literal digest.

- [ ] **Step 4: Regenerate and run tests**

```bash
python3 tools/generate_protocol_vectors.py --output protocol/test-vectors/dbp-v1.json
python3 -m unittest tools.tests.test_protocol_vectors -v
```

Expected: PASS; a second generation produces no diff.

- [ ] **Step 5: Commit**

```bash
git add protocol tools/generate_protocol_vectors.py tools/tests/test_protocol_vectors.py
git commit -m "feat(protocol): define DBP UDP extension"
```

---

### Task 2: C DBP OPEN_UDP and datagram frame codec

**Files:**
- Modify: `core/include/droidbridge_protocol.h`
- Modify: `core/src/dbp_codec.c`
- Modify: `core/tests/test_dbp_codec.c`
- Create: `core/fuzz/fuzz_open_udp.c`
- Create: `core/fuzz/fuzz_udp_frame.c`
- Modify: `core/CMakeLists.txt`

**Interfaces:**
- Consumes: canonical B2 fixture.
- Produces: `dbp_encode_open_udp`, `dbp_decode_open_udp`, `dbp_encode_udp_frame_header`, `dbp_decode_udp_frame_header`.

- [ ] **Step 1: Write failing codec tests**

```c
static void test_open_udp_round_trip(void) {
    dbp_open_udp_t input = {
        .address = {93, 184, 216, 34},
        .port = 443,
        .idle_timeout_seconds = 120,
    };
    uint8_t payload[10];
    ASSERT_EQ_SIZE(10, dbp_encode_open_udp(payload, sizeof(payload), &input));
    dbp_open_udp_t output = {0};
    ASSERT_EQ_INT(DBP_OK, dbp_decode_open_udp(payload, sizeof(payload), &output));
    ASSERT_MEM_EQ(&input, &output, sizeof(input));
}

static void test_udp_frame_rejects_reserved_and_oversize(void) {
    uint8_t header[8] = {0x04, 0xd1, 0, 0, 0, 0, 0, 1};
    dbp_udp_frame_header_t decoded;
    ASSERT_EQ_INT(DBP_ERR_PAYLOAD_SIZE, dbp_decode_udp_frame_header(header, 8, &decoded));
    header[0] = 0; header[1] = 1; header[3] = 1;
    ASSERT_EQ_INT(DBP_ERR_RESERVED, dbp_decode_udp_frame_header(header, 8, &decoded));
}
```

Add fixture parity tests for every generated vector and all unknown flags.

- [ ] **Step 2: Run and verify failure**

```bash
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Debug
cmake --build build/core --parallel
ctest --test-dir build/core -R dbp_codec --output-on-failure
```

Expected: compile failure because UDP codec symbols are undefined.

- [ ] **Step 3: Implement bounded codecs**

Add exact public types:

```c
#define DBP_UDP_MAX_PAYLOAD 1232u

typedef struct {
    uint8_t address[4];
    uint16_t port;
    uint16_t idle_timeout_seconds;
} dbp_open_udp_t;

typedef struct {
    uint16_t payload_length;
    uint8_t flags;
    uint32_t sequence;
} dbp_udp_frame_header_t;
```

Use explicit big-endian byte operations. Reject port 0, timeout outside 30...300, address type not 1, address length not 4, payload size not 10, flags outside `0x03`, non-zero reserved, and payload length above 1,232.

- [ ] **Step 4: Run codec and fuzz smoke tests**

```bash
cmake --build build/core --parallel
ctest --test-dir build/core -R dbp_codec --output-on-failure
./build/core/fuzz_open_udp -runs=10000
./build/core/fuzz_udp_frame -runs=10000
```

Expected: all tests pass and fuzzers exit 0.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): add DBP UDP codecs"
```

---

### Task 3: IPv4 UDP parser and checksum primitives

**Files:**
- Create: `core/include/droidbridge_udp.h`
- Create: `core/src/udp_packet.c`
- Modify: `core/src/checksum.c`
- Create: `core/tests/test_ipv4_udp.c`
- Modify: `core/tests/packet_builder.h`
- Modify: `core/tests/packet_builder.c`
- Modify: `core/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: validated IPv4 packet buffer.
- Produces: `db_udp_parse_ipv4`, `db_udp_checksum_ipv4`, `db_udp_build_ipv4_response`.

- [ ] **Step 1: Write failing packet tests**

```c
static void test_parse_valid_odd_length_udp_payload(void) {
    uint8_t packet[128];
    size_t length = build_ipv4_udp(packet, sizeof(packet),
        "198.18.0.2", 51000, "93.184.216.34", 443,
        (const uint8_t *)"abcde", 5, true);
    db_udp_packet_v4_t parsed = {0};
    ASSERT_EQ_INT(DB_UDP_OK, db_udp_parse_ipv4(packet, length, &parsed));
    ASSERT_EQ_INT(51000, parsed.source_port);
    ASSERT_EQ_INT(443, parsed.destination_port);
    ASSERT_EQ_SIZE(5, parsed.payload_length);
}

static void test_fragment_is_rejected(void) {
    uint8_t packet[128];
    size_t length = build_ipv4_udp_fragment(packet, sizeof(packet), true, 0);
    db_udp_packet_v4_t parsed = {0};
    ASSERT_EQ_INT(DB_UDP_FRAGMENTED, db_udp_parse_ipv4(packet, length, &parsed));
}
```

Add tests for IHL 4/15, total length short/long, UDP length 7, checksum zero, corrupt checksum, 1,232 payload, 1,233 payload, and response checksum result zero encoded as `0xffff`.

- [ ] **Step 2: Run and verify failure**

```bash
cmake --build build/core --parallel
ctest --test-dir build/core -R ipv4_udp --output-on-failure
```

Expected: compile failure because UDP packet APIs do not exist.

- [ ] **Step 3: Implement strict parser and builder**

Expose this immutable parse view:

```c
typedef struct {
    uint32_t source_address;
    uint32_t destination_address;
    uint16_t source_port;
    uint16_t destination_port;
    const uint8_t *payload;
    size_t payload_length;
} db_udp_packet_v4_t;
```

Never retain `payload` after the input callback returns. `db_udp_build_ipv4_response` accepts a caller-owned output buffer, checks capacity, sets DF, increments an injected 16-bit IP ID counter, and returns exact bytes written.

- [ ] **Step 4: Run tests and sanitizers**

```bash
cmake -S core -B build/core-asan -DCMAKE_BUILD_TYPE=Debug -DDB_ENABLE_SANITIZERS=ON
cmake --build build/core-asan --parallel
ctest --test-dir build/core-asan -R ipv4_udp --output-on-failure
```

Expected: PASS with no sanitizer findings.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): parse and synthesize IPv4 UDP"
```

---

### Task 4: Bounded UDP flow table and timeout lifecycle

**Files:**
- Create: `core/src/udp_flow_table.c`
- Create: `core/include/droidbridge_udp_flow.h`
- Create: `core/tests/test_udp_flow_table.c`
- Modify: `core/CMakeLists.txt`

**Interfaces:**
- Consumes: `db_udp_flow_key_v4_t`, monotonic milliseconds, limit configuration.
- Produces: `db_udp_flow_table_create`, `db_udp_flow_get_or_create`, `db_udp_flow_touch`, `db_udp_flow_remove`, `db_udp_flow_sweep`.

- [ ] **Step 1: Write failing lifecycle tests**

```c
static void test_same_source_port_different_destination_is_distinct(void) {
    db_udp_flow_table_t *table = db_udp_flow_table_create(128, 256);
    db_udp_flow_key_v4_t a = key("198.18.0.2", 50000, "1.1.1.1", 443);
    db_udp_flow_key_v4_t b = key("198.18.0.2", 50000, "8.8.8.8", 443);
    ASSERT_NE_U64(db_udp_flow_get_or_create(table, &a, 0, 120000).flow_id,
                  db_udp_flow_get_or_create(table, &b, 0, 120000).flow_id);
    db_udp_flow_table_destroy(table);
}

static void test_sweep_closes_once(void) {
    close_recorder_t recorder = {0};
    db_udp_flow_table_t *table = table_with_close_callback(&recorder);
    db_udp_flow_result_t flow = create_default_flow(table, 0);
    ASSERT_EQ_SIZE(1, db_udp_flow_sweep(table, 120001));
    ASSERT_FALSE(db_udp_flow_remove(table, flow.flow_id, DB_UDP_CLOSE_EXPLICIT));
    ASSERT_EQ_SIZE(1, recorder.count);
}
```

Add hard-limit, ID wrap, touch extends timeout, and destroy closes all flows tests.

- [ ] **Step 2: Run and verify failure**

```bash
cmake --build build/core --parallel
ctest --test-dir build/core -R udp_flow_table --output-on-failure
```

Expected: compile failure because table APIs do not exist.

- [ ] **Step 3: Implement deterministic table semantics**

Use an open-addressed table sized to the next power of two above `hard_limit * 2`. Flow IDs are non-zero monotonic `uint64_t`; skip 0 on wrap. Each record stores `created_ms`, `last_activity_ms`, `idle_timeout_ms`, and a state `OPENING/OPEN/CLOSING/CLOSED`. Removal transitions through CLOSING once before invoking the close callback.

- [ ] **Step 4: Run tests under ASan and TSan-compatible single-thread harness**

```bash
cmake --build build/core-asan --parallel
ctest --test-dir build/core-asan -R udp_flow_table --output-on-failure
```

Expected: PASS; no double callback or leak.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): add bounded UDP flow table"
```

---

### Task 5: UDP packet engine callback ABI and queue policy

**Files:**
- Modify: `core/include/droidbridge_core.h`
- Create: `core/src/udp_engine.c`
- Modify: `core/src/packet_engine.c`
- Create: `core/tests/test_packet_engine_udp.c`
- Modify: `core/tests/test_main.c`
- Modify: `core/CMakeLists.txt`

**Interfaces:**
- Consumes: IPv4 UDP parser, flow table, destination policy.
- Produces: callbacks `on_udp_open`, `on_udp_datagram`, `on_udp_close`; APIs `db_engine_udp_opened`, `db_engine_udp_deliver`, `db_engine_udp_failed`.

- [ ] **Step 1: Write failing engine tests**

```c
static void test_first_datagram_opens_flow_then_queues_payload(void) {
    engine_recorder_t recorder = make_recorder();
    db_engine_t *engine = make_engine(&recorder);
    uint8_t packet[1500];
    size_t length = build_public_udp_packet(packet, sizeof(packet), 443, "first", 5);

    ASSERT_EQ_INT(DB_ENGINE_CONSUMED, db_engine_input(engine, packet, length, 1000));
    ASSERT_EQ_SIZE(1, recorder.udp_open_count);
    ASSERT_EQ_SIZE(0, recorder.udp_datagram_count);

    db_engine_udp_opened(engine, recorder.last_flow_id, 1001);
    ASSERT_EQ_SIZE(1, recorder.udp_datagram_count);
    ASSERT_MEM_EQ("first", recorder.last_payload, 5);
}

static void test_queue_overflow_drops_oldest(void) {
    engine_recorder_t recorder = make_recorder_with_queue_limit(2);
    db_engine_t *engine = open_udp_flow(&recorder);
    inject_payload(engine, "one"); inject_payload(engine, "two"); inject_payload(engine, "three");
    ASSERT_EQ_SIZE(1, db_engine_metrics(engine).udp_queue_drops);
    ASSERT_STR_EQ("two", dequeue_payload(engine));
    ASSERT_STR_EQ("three", dequeue_payload(engine));
}
```

Add private destination, DNS virtual address bypass to DNS engine, remote response synthesis, failure cleanup, and 256-flow limit tests.

- [ ] **Step 2: Run and verify failure**

```bash
cmake --build build/core --parallel
ctest --test-dir build/core -R packet_engine_udp --output-on-failure
```

Expected: compile failure because UDP callbacks/APIs are undefined.

- [ ] **Step 3: Implement the ABI and bounded queues**

Add callbacks with explicit buffer lifetime:

```c
typedef void (*db_on_udp_open_fn)(void *ctx, uint64_t flow_id,
    const db_udp_flow_key_v4_t *key, uint16_t idle_seconds);
typedef void (*db_on_udp_datagram_fn)(void *ctx, uint64_t flow_id,
    const uint8_t *payload, size_t length);
typedef void (*db_on_udp_close_fn)(void *ctx, uint64_t flow_id,
    db_udp_close_reason_t reason);
```

The callback must copy payload before returning. Implement per-flow ring buffers capped by datagram count and bytes. On overflow, release the oldest owned buffer and increment `udp_queue_drops`.

- [ ] **Step 4: Run the complete core test suite**

```bash
cmake --build build/core-asan --parallel
ctest --test-dir build/core-asan --output-on-failure
```

Expected: all B1 and B2 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): integrate IPv4 UDP packet engine"
```

---

### Task 6: UDP fuzz targets and B2 core gate

**Files:**
- Create: `core/fuzz/fuzz_ipv4_udp.c`
- Create: `core/fuzz/fuzz_udp_engine.c`
- Modify: `.github/workflows/foundation.yml`
- Modify: `Makefile`
- Create: `scripts/verify-b2-core.sh`

**Interfaces:**
- Consumes: all B2 core binaries and frozen fixtures.
- Produces: `make verify-b2-core` release gate.

- [ ] **Step 1: Write a failing gate test**

```bash
#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest tools.tests.test_protocol_vectors -v
cmake -S core -B build/core-b2 -DCMAKE_BUILD_TYPE=RelWithDebInfo -DDB_ENABLE_SANITIZERS=ON
cmake --build build/core-b2 --parallel
ctest --test-dir build/core-b2 --output-on-failure
./build/core-b2/fuzz_ipv4_udp -runs=20000
./build/core-b2/fuzz_udp_engine -runs=20000
```

Add `make verify-b2-core` to call this script.

- [ ] **Step 2: Run and verify failure**

```bash
make verify-b2-core
```

Expected: FAIL because fuzz targets and Make target do not exist.

- [ ] **Step 3: Implement fuzz harnesses and CI job**

`fuzz_ipv4_udp` calls only `db_udp_parse_ipv4`. `fuzz_udp_engine` creates a deterministic engine with limits 8/16, feeds arbitrary bytes, advances time by the first four fuzz bytes interpreted as milliseconds, and destroys the engine. No network or filesystem access is permitted.

CI runs unit tests on every commit and 20,000 fuzz iterations on pull requests. A nightly job runs 1,000,000 iterations per target.

- [ ] **Step 4: Run the gate twice**

```bash
make verify-b2-core
make verify-b2-core
```

Expected: both runs PASS and generated files remain unchanged.

- [ ] **Step 5: Commit**

```bash
git add core .github Makefile scripts/verify-b2-core.sh
git commit -m "test(core): add B2 UDP verification gate"
```
