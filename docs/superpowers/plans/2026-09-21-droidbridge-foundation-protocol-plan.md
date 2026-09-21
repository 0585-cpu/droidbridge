# DroidBridge Foundation and DBP/1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DroidBridge의 재현 가능한 저장소 기반, DBP/1 와이어 규격·공통 테스트 벡터, C17 codec·IPv4 destination policy library, 독립 probe client를 구축한다.

**Architecture:** `protocol/`이 모든 언어 구현의 source of truth가 되고 Python generator가 canonical HMAC·encoding fixture를 만든다. C library는 DBP header/payload의 구조 검증과 목적지 CIDR 정책만 담당하며 cryptographic key storage나 socket I/O를 수행하지 않는다. `tools/dbp_probe.py`는 Android relay가 완성되기 전후에 wire compatibility를 검증하는 개발용 client다.

**Tech Stack:** C17, CMake 3.28+, CTest, Clang sanitizers/libFuzzer, Python 3.11+, standard library only

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`

## Global Constraints

- DBP/1 공통 header는 정확히 64 bytes다.
- HMAC은 SHA-256이고 HMAC field를 32 bytes zero로 만든 header와 payload 전체를 입력으로 사용한다.
- timestamp 허용 편차는 120초, nonce replay window는 5분·최근 1024개다.
- B1 message type은 `HELLO`, `HELLO_OK`, `OPEN_TCP`, `OPEN_OK`, `OPEN_ERROR`, `DNS_QUERY`, `DNS_RESPONSE`, `HEALTH`, `HEALTH_RESPONSE`만 허용하고 flags는 항상 `0`이어야 한다.
- `OPEN_TCP` address type은 IPv4 `1`, domain `3`만 허용한다.
- domain은 ASCII/IDNA wire representation 기준 1~253 bytes, destination port는 1~65535다.
- 목적지 정책은 명세 10절의 IPv4 대역을 기본 차단한다.
- payload 내용은 fixture 외 로그에 기록하지 않는다.
- license는 BSD-3-Clause로 시작하며 외부 의존성은 이 계획에서 추가하지 않는다.

## Review Focus

- `header_length`가 64보다 작거나 packet length보다 크면 out-of-bounds read 없이 `DBP_ERR_TRUNCATED`를 반환해야 한다.
- unknown message type, address type, zero port, oversized domain은 parse success가 아니라 명시적 validation error여야 한다.
- 네트워크 바이트 순서와 host 바이트 순서 혼동 없이 test vector와 byte-for-byte 일치해야 한다.
- 차단 CIDR의 첫 주소·마지막 주소와 바로 인접한 허용 주소를 모두 테스트해야 한다.
- HMAC fixture generator가 시스템 시간·난수에 의존하지 않아 같은 commit에서 항상 동일한 JSON을 생성해야 한다.

---

### Task 1: Repository foundation and deterministic verification entrypoint

**Files:**
- Create: `.gitignore`
- Create: `.editorconfig`
- Create: `LICENSE`
- Create: `SECURITY.md`
- Create: `README.md`
- Create: `Makefile`
- Create: `core/CMakeLists.txt`
- Create: `core/tests/CMakeLists.txt`
- Create: `core/tests/test_main.c`
- Create: `core/src/self_test.c`
- Create: `tools/check_environment.py`

**Interfaces:**
- Consumes: 승인된 설계 명세와 roadmap의 global constraints.
- Produces: `make configure-core`, `make test-core`, `make verify-foundation`; CTest executable `droidbridge_core_tests`.

- [ ] **Step 1: Write the failing environment test**

Create `tools/check_environment.py`:

```python
#!/usr/bin/env python3
from __future__ import annotations

import shutil
import subprocess
import sys

REQUIRED = {"cmake": (3, 28), "python3": (3, 11)}


def version(command: str) -> tuple[int, int]:
    output = subprocess.check_output([command, "--version"], text=True).splitlines()[0]
    numbers = [int(part) for part in output.replace("Python ", "").split()[-1].split(".")[:2]]
    return numbers[0], numbers[1]


def main() -> int:
    failures: list[str] = []
    for command, minimum in REQUIRED.items():
        path = shutil.which(command)
        if path is None:
            failures.append(f"missing: {command}")
            continue
        actual = version(command)
        if actual < minimum:
            failures.append(f"{command} {actual[0]}.{actual[1]} < {minimum[0]}.{minimum[1]}")
    if failures:
        print("\n".join(failures), file=sys.stderr)
        return 1
    print("environment: ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

Create `core/tests/test_main.c` with a reference to an as-yet undefined function so the first build fails:

```c
#include <stdio.h>
int dbp_codec_self_test(void);

int main(void) {
    if (dbp_codec_self_test() != 0) {
        fprintf(stderr, "dbp codec self test failed\n");
        return 1;
    }
    return 0;
}
```

- [ ] **Step 2: Run the checks and confirm the expected failure**

Run:

```bash
python3 tools/check_environment.py
cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Debug
cmake --build build/core
```

Expected: environment check prints `environment: ok`; link fails with `undefined symbol: dbp_codec_self_test`.

- [ ] **Step 3: Add the minimal build skeleton and project metadata**

`core/CMakeLists.txt`:

```cmake
cmake_minimum_required(VERSION 3.28)
project(droidbridge_core VERSION 0.1.0 LANGUAGES C)
set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_C_EXTENSIONS OFF)
include(CTest)
add_library(droidbridge_protocol STATIC src/self_test.c)
target_include_directories(droidbridge_protocol PUBLIC include)
if(BUILD_TESTING)
  add_subdirectory(tests)
endif()
```

`core/src/self_test.c`:

```c
int dbp_codec_self_test(void) { return 0; }
```

`core/tests/CMakeLists.txt`:

```cmake
add_executable(droidbridge_core_tests test_main.c)
target_link_libraries(droidbridge_core_tests PRIVATE droidbridge_protocol)
add_test(NAME droidbridge_core_tests COMMAND droidbridge_core_tests)
```

`Makefile` must contain these exact targets:

```make
.PHONY: configure-core test-core verify-foundation
configure-core:
	cmake -S core -B build/core -DCMAKE_BUILD_TYPE=Debug -DCMAKE_EXPORT_COMPILE_COMMANDS=ON

test-core: configure-core
	cmake --build build/core --parallel
	ctest --test-dir build/core --output-on-failure

verify-foundation: test-core
	python3 tools/check_environment.py
	python3 tools/generate_protocol_vectors.py --check
```

Add a BSD-3-Clause `LICENSE`, a security contact process in `SECURITY.md`, build output/IDE/secret exclusions in `.gitignore`, and LF/UTF-8/C-Swift-Kotlin indentation rules in `.editorconfig`.

- [ ] **Step 4: Run the build and verify it passes**

Run:

```bash
make test-core
```

Expected: one CTest named `droidbridge_core_tests` passes.

- [ ] **Step 5: Commit**

```bash
git add .gitignore .editorconfig LICENSE SECURITY.md README.md Makefile core tools/check_environment.py
git commit -m "build: establish droidbridge foundation"
```

### Task 2: Canonical DBP/1 protocol document and deterministic fixtures

**Files:**
- Create: `protocol/dbp-v1.md`
- Create: `protocol/test-vectors/dbp-v1.json`
- Create: `tools/generate_protocol_vectors.py`
- Create: `tools/tests/test_protocol_vectors.py`

**Interfaces:**
- Consumes: DBP/1 fields and error codes from the approved spec.
- Produces: canonical JSON fixture schema `dbp-vectors-v1`; helper functions `encode_header(fields, hmac_bytes)` and `compute_hmac(secret, header, payload)` used only by the generator/probe.

- [ ] **Step 1: Write the failing generator test**

Create `tools/tests/test_protocol_vectors.py`:

```python
from pathlib import Path
import json
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def test_fixture_is_reproducible() -> None:
    subprocess.run(
        [sys.executable, str(ROOT / "tools/generate_protocol_vectors.py"), "--check"],
        cwd=ROOT,
        check=True,
    )
    document = json.loads((ROOT / "protocol/test-vectors/dbp-v1.json").read_text())
    assert document["schema"] == "dbp-vectors-v1"
    assert document["header_size"] == 64
    assert {item["name"] for item in document["vectors"]} == {
        "hello",
        "hello_ok",
        "open_ipv4_443",
        "open_domain_443",
        "open_ok",
        "open_error_policy_denied",
        "dns_query",
        "dns_response",
        "health",
        "health_response_ready",
    }
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```bash
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
```

Expected: failure because `generate_protocol_vectors.py` and fixture do not exist.

- [ ] **Step 3: Implement the canonical encoder and fixture generator**

Use this wire encoder in `tools/generate_protocol_vectors.py`:

```python
HEADER = struct.Struct("!4sBBHQQQ32s")
MAGIC = b"DBP1"
SECRET = bytes.fromhex("00" * 31 + "01")


def encode_header(message_type: int, flags: int, client_nonce: int,
                  server_nonce: int, unix_time: int, mac: bytes) -> bytes:
    return HEADER.pack(MAGIC, message_type, flags, 64,
                       client_nonce, server_nonce, unix_time, mac)


def compute_hmac(message_type: int, flags: int, client_nonce: int,
                 server_nonce: int, unix_time: int, payload: bytes) -> bytes:
    zero_header = encode_header(message_type, flags, client_nonce,
                                server_nonce, unix_time, bytes(32))
    return hmac.new(SECRET, zero_header + payload, hashlib.sha256).digest()
```

Use fixed timestamp `1_700_000_000`, fixed nonces, and these payload rules:

```text
HELLO, HELLO_OK, OPEN_OK, HEALTH: empty payload
OPEN_TCP IPv4: type(1) | port u16 | length(1) | 4 address bytes
OPEN_TCP domain: type(3) | port u16 | length(1) | ASCII domain bytes
OPEN_ERROR: error code u8
DNS_QUERY, DNS_RESPONSE: DNS packet length u16 | DNS wire packet
HEALTH_RESPONSE:
  status u8 | active sessions u16 | maximum sessions u16 |
  uploaded bytes u64 | downloaded bytes u64 |
  carrier-name length u8 | UTF-8 carrier name (0...63 bytes)
```

All integers are unsigned network byte order. `HELLO_OK` carries the server nonce only in the common header. `OPEN_ERROR` accepts exactly the nine error codes from the approved spec. DNS length must equal the remaining payload and be 12...4096 bytes. `HEALTH_RESPONSE` must be 22...85 bytes, reject invalid UTF-8, reject active sessions greater than maximum sessions, and cap maximum sessions at 256.

The generator writes sorted, indented JSON with hex fields and supports `--check`, which generates in memory and exits non-zero if the committed file differs.

Document the complete 64-byte header, message types, payloads, HMAC input, state transition to raw stream, limits, and error codes in `protocol/dbp-v1.md`.

- [ ] **Step 4: Run the generator and tests**

Run:

```bash
python3 tools/generate_protocol_vectors.py
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
python3 tools/generate_protocol_vectors.py --check
```

Expected: all tests pass and a second generation creates no diff.

- [ ] **Step 5: Commit**

```bash
git add protocol tools/generate_protocol_vectors.py tools/tests
git commit -m "docs: define canonical dbp1 wire protocol"
```

### Task 3: C DBP/1 header and OPEN_TCP codec

**Files:**
- Create: `core/include/droidbridge_protocol.h`
- Create: `core/src/dbp_codec.c`
- Create: `core/tests/test_dbp_codec.c`
- Modify: `core/CMakeLists.txt`
- Modify: `core/tests/CMakeLists.txt`
- Remove: `core/src/self_test.c`
- Modify: `core/tests/test_main.c`

**Interfaces:**
- Consumes: `protocol/test-vectors/dbp-v1.json` semantics.
- Produces: `dbp_encode_header`, `dbp_decode_header`, `dbp_encode_open_tcp`, `dbp_decode_open_tcp`, enum `dbp_status_t`.

- [ ] **Step 1: Write failing codec tests**

Define the public types first in the test so signatures are fixed:

```c
static void test_header_round_trip(void) {
    dbp_header_fields_t fields = {
        .message_type = DBP_MESSAGE_OPEN_TCP,
        .flags = 0,
        .client_nonce = UINT64_C(0x0102030405060708),
        .server_nonce = UINT64_C(0x1112131415161718),
        .unix_time_seconds = UINT64_C(1700000000),
    };
    uint8_t mac[DBP_HMAC_SIZE] = {0};
    uint8_t encoded[DBP_HEADER_SIZE] = {0};
    dbp_header_fields_t decoded = {0};
    uint8_t decoded_mac[DBP_HMAC_SIZE] = {0};

    ASSERT_EQ_INT(DBP_OK, dbp_encode_header(&fields, mac, encoded, sizeof encoded));
    ASSERT_EQ_INT(DBP_OK, dbp_decode_header(encoded, sizeof encoded, &decoded, decoded_mac));
    ASSERT_EQ_INT(fields.message_type, decoded.message_type);
    ASSERT_EQ_U64(fields.client_nonce, decoded.client_nonce);
}

static void test_truncated_and_bad_magic_are_rejected(void) {
    uint8_t bytes[DBP_HEADER_SIZE] = {0};
    dbp_header_fields_t fields = {0};
    uint8_t mac[DBP_HMAC_SIZE] = {0};
    ASSERT_EQ_INT(DBP_ERR_TRUNCATED, dbp_decode_header(bytes, 63, &fields, mac));
    ASSERT_EQ_INT(DBP_ERR_MAGIC, dbp_decode_header(bytes, sizeof bytes, &fields, mac));
}
```

Add OPEN_TCP tests for IPv4 `93.184.216.34:443`, domain `example.com:443`, zero port, domain length 0, domain length 254, unknown address type, non-zero flags, and every unknown message type value.

- [ ] **Step 2: Build and confirm failure**

Run:

```bash
make test-core
```

Expected: compilation fails because protocol symbols are undefined.

- [ ] **Step 3: Implement strict codec functions**

`droidbridge_protocol.h` must define:

```c
#define DBP_HEADER_SIZE 64u
#define DBP_HMAC_SIZE 32u
#define DBP_MAX_DOMAIN_LENGTH 253u

typedef enum {
    DBP_OK = 0,
    DBP_ERR_ARGUMENT = -1,
    DBP_ERR_TRUNCATED = -2,
    DBP_ERR_MAGIC = -3,
    DBP_ERR_HEADER_LENGTH = -4,
    DBP_ERR_MESSAGE_TYPE = -5,
    DBP_ERR_FLAGS = -6,
    DBP_ERR_ADDRESS_TYPE = -7,
    DBP_ERR_PORT = -8,
    DBP_ERR_DOMAIN_LENGTH = -9,
    DBP_ERR_OUTPUT_TOO_SMALL = -10
} dbp_status_t;
```

Implement explicit big-endian `read_u16/read_u64/write_u16/write_u64` helpers with shifts; do not cast unaligned byte buffers to integer pointers. Validate message type against the nine B1 values, reject non-zero flags with `DBP_ERR_FLAGS`, and require header length exactly 64.

For `dbp_open_tcp_t`, store either four IPv4 bytes or a 253-byte domain plus length. Encoding and decoding must never append or require a NUL byte on the wire.

- [ ] **Step 4: Run unit tests with sanitizers**

Run:

```bash
cmake -S core -B build/core-asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer'
cmake --build build/core-asan --parallel
ctest --test-dir build/core-asan --output-on-failure
```

Expected: codec tests pass with no ASan/UBSan reports.

- [ ] **Step 5: Commit**

```bash
git add core
git commit -m "feat(core): add strict dbp1 codec"
```

### Task 4: IPv4 destination policy with boundary fixtures

**Files:**
- Create: `core/include/droidbridge_policy.h`
- Create: `core/src/destination_policy.c`
- Create: `core/tests/test_destination_policy.c`
- Create: `protocol/test-vectors/destination-policy.json`
- Modify: `tools/generate_protocol_vectors.py`
- Modify: `core/CMakeLists.txt`
- Modify: `core/tests/CMakeLists.txt`

**Interfaces:**
- Consumes: blocked CIDRs from spec section 10.
- Produces: `db_policy_check_ipv4(const uint8_t address[4]) -> db_policy_result_t`; generated allowed/denied boundary fixture.

- [ ] **Step 1: Write failing CIDR boundary tests**

Use table-driven tests:

```c
typedef struct {
    uint8_t ip[4];
    db_policy_result_t expected;
} policy_case_t;

static const policy_case_t cases[] = {
    {{10, 0, 0, 0}, DB_POLICY_DENY_PRIVATE},
    {{10, 255, 255, 255}, DB_POLICY_DENY_PRIVATE},
    {{11, 0, 0, 0}, DB_POLICY_ALLOW},
    {{100, 64, 0, 0}, DB_POLICY_DENY_SHARED},
    {{100, 127, 255, 255}, DB_POLICY_DENY_SHARED},
    {{100, 128, 0, 0}, DB_POLICY_ALLOW},
    {{198, 18, 0, 0}, DB_POLICY_DENY_BENCHMARK},
    {{203, 0, 113, 255}, DB_POLICY_DENY_DOCUMENTATION},
    {{224, 0, 0, 0}, DB_POLICY_DENY_MULTICAST},
    {{255, 255, 255, 255}, DB_POLICY_DENY_RESERVED},
    {{93, 184, 216, 34}, DB_POLICY_ALLOW},
};
```

Cover first, last, one-before, and one-after addresses for every CIDR listed in the spec.

- [ ] **Step 2: Run and confirm failure**

Run `make test-core`.

Expected: missing `droidbridge_policy.h` or undefined function failure.

- [ ] **Step 3: Implement policy using integer masks**

Convert bytes to a host `uint32_t` with explicit shifts and compare using `(address & mask) == network`. Return a specific denial reason enum; do not use string parsing in the runtime path.

Extend the Python generator to write `destination-policy.json` from a single `BLOCKED_CIDRS` table and assert the C table matches the document during review. The committed fixture must include each boundary case and `93.184.216.34` as an allowed public address.

- [ ] **Step 4: Run all policy tests**

Run:

```bash
make test-core
python3 tools/generate_protocol_vectors.py --check
```

Expected: all boundary tests pass.

- [ ] **Step 5: Commit**

```bash
git add core protocol/test-vectors tools/generate_protocol_vectors.py
git commit -m "feat(core): enforce public ipv4 destination policy"
```

### Task 5: DBP probe client and mock relay

**Files:**
- Create: `tools/dbp_probe.py`
- Create: `tools/mock_relay.py`
- Create: `tools/tests/test_dbp_probe.py`

**Interfaces:**
- Consumes: DBP fixture encoder and a 32-byte hex Pairing Secret supplied through environment variable `DROIDBRIDGE_TEST_SECRET`.
- Produces: commands `health`, `open`, `dns`; `MockRelay` for Android/macOS tests. The probe refuses to print the secret or application payload.

- [ ] **Step 1: Write failing mock-relay integration tests**

```python
class ProbeIntegrationTest(unittest.IsolatedAsyncioTestCase):
    async def test_health_round_trip(self) -> None:
        relay = MockRelay(secret=bytes.fromhex("00" * 31 + "01"))
        await relay.start("127.0.0.1", 0)
        result = await run_probe_health(relay.port, relay.secret)
        self.assertEqual(result.status, "ok")
        self.assertEqual(result.protocol, "DBP/1")
        await relay.close()

    async def test_wrong_secret_is_rejected(self) -> None:
        relay = MockRelay(secret=bytes.fromhex("00" * 31 + "01"))
        await relay.start("127.0.0.1", 0)
        with self.assertRaises(AuthenticationError):
            await run_probe_health(relay.port, bytes(32))
        await relay.close()
```

Also test timestamp skew of 121 seconds, repeated nonce, truncated header, and payload length over 4096.

- [ ] **Step 2: Run and confirm failure**

Run:

```bash
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
```

Expected: imports fail because probe and mock relay do not exist.

- [ ] **Step 3: Implement standard-library-only async probe**

Implement `asyncio.open_connection`, exact 64-byte reads with `readexactly`, constant-time `hmac.compare_digest`, and a bounded replay cache in the mock. CLI examples must work as written:

```bash
DROIDBRIDGE_TEST_SECRET=<64-hex> python3 tools/dbp_probe.py health --host 127.0.0.1 --port 27183
DROIDBRIDGE_TEST_SECRET=<64-hex> python3 tools/dbp_probe.py open --host 127.0.0.1 --port 27183 --destination example.com:443
DROIDBRIDGE_TEST_SECRET=<64-hex> python3 tools/dbp_probe.py dns --host 127.0.0.1 --port 27183 --name example.com --type A
```

The `open` command completes HELLO and OPEN handshakes, prints only status/destination/latency, then closes without sending HTTP data. The `dns` command builds and parses a minimal DNS packet without external packages.

- [ ] **Step 4: Run tests and a local smoke test**

Run:

```bash
python3 -m unittest discover -s tools/tests -p 'test_*.py' -v
DROIDBRIDGE_TEST_SECRET=$(printf '00%.0s' {1..31}; printf '01') \
  python3 tools/mock_relay.py --port 27183 &
relay_pid=$!
DROIDBRIDGE_TEST_SECRET=$(printf '00%.0s' {1..31}; printf '01') \
  python3 tools/dbp_probe.py health --host 127.0.0.1 --port 27183
kill "$relay_pid"
```

Expected: CLI prints `status=ok protocol=DBP/1` and never prints the secret.

- [ ] **Step 5: Commit**

```bash
git add tools
git commit -m "test: add dbp probe and mock relay"
```

### Task 6: Parser fuzz targets and foundation CI gate

**Files:**
- Create: `core/fuzz/fuzz_dbp_header.c`
- Create: `core/fuzz/fuzz_open_tcp.c`
- Create: `.github/workflows/foundation.yml`
- Modify: `core/CMakeLists.txt`
- Modify: `Makefile`
- Modify: `README.md`

**Interfaces:**
- Consumes: codec/policy public APIs.
- Produces: `make fuzz-smoke`, CI job `foundation`, developer setup instructions.

- [ ] **Step 1: Add fuzz smoke tests that initially fail to build**

`fuzz_dbp_header.c`:

```c
#include <stddef.h>
#include <stdint.h>
#include "droidbridge_protocol.h"

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    dbp_header_fields_t fields = {0};
    uint8_t mac[DBP_HMAC_SIZE] = {0};
    (void)dbp_decode_header(data, size, &fields, mac);
    return 0;
}
```

Create an equivalent OPEN_TCP target that calls `dbp_decode_open_tcp` for every input.

- [ ] **Step 2: Confirm unsupported fuzz target configuration fails cleanly**

Run:

```bash
cmake -S core -B build/core-fuzz -DDROIDBRIDGE_BUILD_FUZZERS=ON -DCMAKE_C_COMPILER=clang
cmake --build build/core-fuzz
```

Expected: failure until fuzz targets and sanitizer flags are defined.

- [ ] **Step 3: Add opt-in libFuzzer targets and CI**

When `DROIDBRIDGE_BUILD_FUZZERS=ON`, compile fuzz targets with:

```cmake
-fsanitize=fuzzer,address,undefined -fno-omit-frame-pointer
```

Add `make fuzz-smoke` to run each target for 10 seconds with `-max_len=4096 -timeout=2`. The GitHub Actions workflow runs on `macos-15` and `ubuntu-24.04`, executes Python tests, ASan/UBSan C tests, fixture check, and the 10-second fuzz smoke run. It must not inject any secret other than the documented all-zero test fixture secret.

- [ ] **Step 4: Run the complete foundation gate**

Run:

```bash
make verify-foundation
make fuzz-smoke
```

Expected: all C/Python tests pass and both fuzz targets exit without crash.

- [ ] **Step 5: Commit**

```bash
git add core/fuzz core/CMakeLists.txt Makefile README.md .github/workflows/foundation.yml
git commit -m "ci: gate protocol foundation with sanitizers and fuzzing"
```

## Foundation completion gate

Run exactly:

```bash
make verify-foundation
make fuzz-smoke
git status --short
```

Expected:

```text
100% tests passed
protocol vectors: unchanged
fuzz_dbp_header: no crash
fuzz_open_tcp: no crash
```

`git status --short` must print nothing. The next plan may start only after this gate passes.
