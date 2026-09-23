# DroidBridge UDP·QUIC 및 트래픽 프로필 Implementation Plan

> 전송 계층은 [AOA 설계](../specs/2026-09-23-droidbridge-aoa-design.md)로 갱신됐다. UDP·QUIC·TTL 범위는 유지하며 AOA 실기기 검증 이후 진행한다.
> **For agentic workers:** 구현 시 `superpowers:executing-plans`를 사용해 체크박스를 추적한다. 기존 상세 계획에는 아래 변경점을 먼저 적용한다. 이 문서 작성은 기능 구현이나 시험 통과를 뜻하지 않는다.

**Goal:** TCP/DNS 터널 안정화 → 일반 UDP·QUIC → 선택형 TTL·트래픽 조절 → IPv6·복구를 순서대로 제공한다.

**Architecture:** signed root utun helper, configd, pf, USB AOA와 Android cellular-bound relay를 사용한다. UDP는 flow별 DBP 세션으로 전달하고 트래픽 프로필은 Android 외부 소켓과 relay queue에 적용한다.

**Tech Stack:** C17/lwIP, Swift 6/SwiftUI/CoreHost, Kotlin/Coroutines/public socket APIs, Python, CMake/CTest, macOS Checks.

**Spec:** [2026-09-23 설계 보충](../specs/2026-09-23-droidbridge-udp-traffic-profile-design.md), 기존 [B2 명세](../specs/2026-09-21-droidbridge-b2-udp-quic-design.md), [B3 명세](../specs/2026-09-21-droidbridge-b3-dual-stack-resilience-design.md). 보충 문서의 변경점이 우선한다.

## Global Constraints

- macOS 14+/Apple Silicon, Android API 26+, Android root 불필요.
- USB AOA 및 loopback-only Android relay 유지.
- 모든 외부 소켓은 선택된 cellular Network에 bind. 회선 손실·실패 시 다른 회선 fallback 금지.
- 기본 MTU 1,280, B2 UDP payload 최대 1,232 bytes, fragment 재조립 없음.
- UDP flow 기본 128/최대 256, TCP+UDP 최대 512, idle 기본 120초/30–300초, sweep 5초.
- 방향별 UDP queue는 64 datagrams 또는 256 KiB, overflow는 drop-oldest.
- TTL/Hop Limit 기본값 유지 또는 사용자 지정 1–255. 필터·shaping 기본 OFF.
- APN/DUN·통신사 설정·휴대폰 전체 IPv6 변경 없음. TLS 복호화 없음.
- payload, DNS name, secret, SNI, URL, 일반 목적지 이력을 로그·evidence에 저장하지 않는다.
- 통신사 분류/과금 변화는 별도 관측 항목이며 기능 효과로 보장하지 않는다.

## Review Focus

- 구형 Android와 새 Mac: TCP/DNS 유지 및 UDP·프로필 미지원 표시. 단계 2.1/3.1 시험.
- 인증/open 도중 Stop·셀룰러 변경: 늦게 완성된 세션도 닫고 이전 generation 데이터 차단. 단계 2.2/2.3 시험.
- zero-length UDP·큰 datagram·fragment: 경계 보존, 명시적 drop, bounded allocation. 단계 2.1/2.2 시험.
- TTL 설정 오류와 mapped IPv6/464XLAT: 성공 표시 없이 flow close. 단계 3.1 시험.
- shaping 포화·취소·설정 변경: 메모리 제한, Stop 완료, 실행 중 편집 거부. 단계 3.2 시험.

## 현재 기준선과 일정

기준 commit은 `9d94ede`다. TCP/DNS/helper는 구현되어 있고 B1 실기기 acceptance가 남아 있다. 일반 UDP는 아직 없다. 앞선 검사에서 C/macOS/helper 테스트는 통과했지만 Android 강제 재실행은 83개 중 2개 실패했다. 실제 pairing 포트 27184에 ADB listener가 관측되었으므로 테스트 의존성을 먼저 제거한다. 이 문서 작성 중 제품 테스트를 다시 실행한 것은 아니다.

날짜 대신 gate로 관리한다. B1 1시간, B2 2시간, B3 8시간 soak는 개발 시간과 별도로 필요한 실측 시간이다. 기기·서명·별도 Mac 회선·제어 가능한 UDP/HTTP3 endpoint 준비 상태가 실기기 일정에 영향을 준다.

| 단계 | 결과 | 완료 기준 |
|---|---|---|
| 1 | 안정적인 TCP/DNS USB 터널 | B1 14개 acceptance |
| 2 | 일반 IPv4 UDP·QUIC/HTTP3 | B1 회귀 + B2 14개 acceptance |
| 3 | TTL·DNS 필터·전송률/버스트 조절 | OFF 회귀 + 프로필별 효과·실패 시험 |
| 4 | IPv6/Hop Limit·ICMP capability·복구 | B1/B2/프로필 회귀 + B3 gate |

## 1. B1 안정화

**Files:** `android/app/src/main/java/io/droidbridge/ui/AppPairingFacade.kt`, `android/app/src/test/java/io/droidbridge/pairing/PairingServerTest.kt`, `scripts/b1-*.sh`, `tools/b1_acceptance.py`, `docs/utun-helper-status.md`. Timeout 수정은 원인을 확인한 TCP/DNS 경로에 한정한다.

- [ ] `AppPairingFacade`에 `serverFactory: () -> PairingServer = { PairingServer() }`를 주입하는 회귀시험을 작성한다. 운영 포트 기본값은 유지한다.
- [ ] 충돌 시험은 열린 `ServerSocket(0)`의 `localPort`를 factory에 전달하고, 재시작 시험은 `PairingServer(0)`을 사용한다. 테스트 때문에 실제 ADB forward를 제거하지 않는다.
- [ ] 포트 분리 후에도 재시작 상태 경합이 발생하면 이전 coordinator의 상태 수집 취소/generation을 검증·수정한다.
- [ ] 간헐 TCP timeout을 제어된 여러 endpoint에서 재현한다. relay open, cellular connect, 첫 byte 수신 중 실패 단계를 구분해 수정한다. 특정 공용 IP의 통신사 차단을 원인으로 가정하지 않는다.
- [ ] 자동 검증과 Android 강제 재실행을 수행한다.

```bash
make verify-foundation
make check-macos
make check-macos-helper
make test-android
# android 디렉터리, 기존 JDK 17 JAVA_HOME 환경에서 실행
./gradlew testDebugUnitTest --rerun-tasks
```

- [ ] USB/relay/cellular/sleep 4종 장애와 복구, 128 TCP flows, 1시간 soak, 성능, 다른 Mac 회선과 구별되는 출구를 확인한다.
- [ ] `make b1-acceptance`의 14개 항목 모두 PASS일 때 B1 gate를 닫는다. 연결을 끊거나 pairing을 바꾸는 실기기 절차는 사용자의 현재 작업 상태와 조율한다.

## 2. 일반 UDP·QUIC

### 2.1 Protocol·C UDP 엔진

**상세 작업:** [B2 protocol/core 계획](2026-09-21-droidbridge-b2-protocol-udp-core-plan.md)의 TDD 단계.

**Files:** `protocol/dbp-v1.md`, `tools/generate_protocol_vectors.py`, `core/include/droidbridge_protocol.h`, `core/src/dbp_codec.c`, `core/src/packet_engine.c`; 신규 UDP parser/engine와 대응 C tests/fuzz targets.

- [ ] B1 wire encoding을 고정하고 구형 peer와 capability 협상/미지원 동작을 fixture로 정의한다.
- [ ] C/Kotlin/Swift가 같은 OPEN_UDP·datagram fixture를 읽게 한다. header 분할, 중간 EOF, reserved/flag 오류, 길이 0/1,232/1,233을 검증한다.
- [ ] checksum, fragment, 목적지 정책, 5-tuple 충돌, idle cleanup, flow limit, close-once를 시험하고 구현한다.
- [ ] 현재 UDP/53 DNS interception이 일반 UDP보다 우선하는 회귀시험을 추가한다.
- [ ] `make verify-foundation`과 UDP fuzz target을 포함한 `make fuzz-smoke`를 통과시킨다.

### 2.2 Android cellular UDP relay

**상세 작업:** [B2 Android 계획](2026-09-21-droidbridge-b2-android-udp-relay-plan.md).

**Files:** 신규 `network/CellularUdpTransport.kt`, `network/AndroidCellularUdpTransport.kt`, `relay/UdpRelaySession.kt`; 기존 `relay/RelayServer.kt`, `relay/AndroidRelayBackend.kt`, `relay/RelayMetrics.kt`. 기준 디렉터리는 `android/app/src/main/java/io/droidbridge/`다.

- [ ] bind→connect 순서, bind 실패 시 close/no-fallback을 시험한다.
- [ ] open 전후 Network generation을 검사하고 onLost, 인증 중 Stop, receive 중 취소 시 socket/coroutine 정리를 검증한다.
- [ ] datagram 수·byte 제한, drop-oldest, zero-length를 구현한다. 큰 수신 datagram이 잘린 정상 packet으로 전달되지 않게 초과 크기를 검출한다.
- [ ] TCP/DNS와 병행하고 `make test-android` 및 실제 cellular binding 시험을 통과시킨다.

### 2.3 macOS helper 통합

**상세 작업:** [B2 macOS 계획](2026-09-21-droidbridge-b2-macos-udp-quic-plan.md)에 다음 경로·명령 교정을 적용한다.

| 기존 대상 | 현재 대상 |
|---|---|
| PacketTunnel의 UDPSessionManager/UDPFlowModels | 신규 `macos/CoreHost/UDPSessionManager.swift`, `UDPFlowModels.swift` |
| NE packetFlow 통합 | `macos/CoreHost/EngineBridge.swift`, `CoreCallbacks.swift`, `TunnelController.swift` |
| provider metrics | `TunnelMetricsSnapshot.swift` → helper XPC → HostApp |
| Shared XCTest 전제 | 기존 `macos/Shared/Sources/Checks` executable |
| NE 전용 통합시험 | `macos/HelperChecks`에서 CoreHost를 빌드·호출하는 시험 및 signed helper 실기기 검증 |

- [ ] Shared Relay 계층에 datagram codec, bounded queue, RelayDatagramConnection을 추가한다.
- [ ] engine callback bytes를 소유하는 Data로 복사하고 단일 engine queue 경계를 유지한다.
- [ ] UDP open/close 경쟁, Stop 후 지연 응답, 이전 generation packet, timer 해제, flow count 정리를 시험한다.
- [ ] `project.yml`, `scripts/check-macos-helper.sh`에 실제 통합한 CoreHost 경로의 검증을 연결한다.
- [ ] macOS/helper checks, signed build를 통과시키고 UDP 지원 상태·drop metric을 UI에 표시한다.

### 2.4 실제 UDP·HTTP/3 수용시험

**상세 작업:** [B2 integration/release 계획](2026-09-21-droidbridge-b2-integration-release-plan.md).

- [ ] preflight의 NE entitlement 요구를 helper 서명/설치/XPC 권한/configd/pf 검증으로 교체한다.
- [ ] 제어 가능한 UDP echo/sequence·HTTP3 endpoint와 harness를 준비한다. 서버가 없으면 실기기 결과는 NOT_RUN으로 남긴다.
- [ ] HTTP3 지원 curl의 `--http3-only`로 버전 3과 10 MiB 전송 성공을 확인한다.
- [ ] payload 0/1/1,200/1,232 전달, 1,233 drop, 100 flows 10분, 혼합 TCP/UDP 2시간 soak를 수행한다.
- [ ] 기존 UDP 15 Mbps 목표, 내부 queue drop 0.5% 이하를 평가한다. one-way jitter 25 ms 목표는 clock 동기화/오차를 제시할 때만 판정하고 RTT를 one-way로 표기하지 않는다.
- [ ] USB/relay/cellular/sleep 장애 시 physical IPv4/IPv6 egress가 없고 복구 후 새 UDP/QUIC 연결이 동작하는지 확인한다.
- [ ] 같은 commit의 B1 회귀 + B2 14개 기준 evidence로 B2 gate를 닫는다.

## 3. TTL·트래픽 프로필

### 3.1 소켓별 TTL

**Create:** Android `network/SocketEgressPolicy.kt`, `network/AndroidSocketPolicyApplier.kt`, 같은 패키지 unit/instrumented tests.

**Modify:** `AndroidCellularTransport.kt`, `AndroidDnsTransport.kt`, 단계 2의 `AndroidCellularUdpTransport.kt`, `RelayServiceController.kt`, `ui/RelayScreen.kt`, protocol/health codecs.

**계약:** null은 OS 기본값, 지정값은 1–255. 원본 소켓은 생성자가 소유하고 applier는 복제 FD만 닫는다. 실행 중 설정 변경은 거부한다.

```kotlin
data class SocketEgressPolicy(
    val ipv4Ttl: Int? = null,
    val ipv6HopLimit: Int? = null,
) {
    init {
        require(ipv4Ttl == null || ipv4Ttl in 1..255)
        require(ipv6HopLimit == null || ipv6HopLimit in 1..255)
    }
}
```

먼저 추가할 unit test:

```kotlin
@Test fun `default leaves OS values unchanged`() {
    assertEquals(SocketEgressPolicy(null, null), SocketEgressPolicy())
}
@Test fun `invalid TTL is rejected before opening a socket`() {
    for (value in listOf(-1, 0, 256)) {
        assertFailsWith<IllegalArgumentException> { SocketEgressPolicy(ipv4Ttl = value) }
    }
}
```

- [ ] 위 테스트의 실패를 확인한 뒤 구현하고 OFF/1/64/65/255, 잘못된 저장 설정의 복원도 시험한다.
- [ ] 공개 API로 cellular bind→set/get TTL→connect를 TCP/DNS/UDP에 적용한다. FD close, 적용 오류, mapped address, 464XLAT를 instrumented test로 검증한다.
- [ ] 적용 실패 시 close와 구조화된 오류, 실행 중 편집 거부, 재시작 시 일관된 적용을 시험한다.
- [ ] 활성 프로필 상태를 capability/version 응답으로 Mac에 전달하고 구형 health decoder 회귀를 확인한다.
- [ ] 휴대폰 직접 연결과 DroidBridge의 생성 시험 트래픽을 같은 endpoint에서 비교한다. socket 되읽기와 외부 헤더 변화를 모두 기록한다.
- [ ] Android/macOS checks와 기본 프로필의 B1/B2 회귀를 통과시킨다.

### 3.2 DNS 필터·전송률·버스트

**Create:** Android `policy/DnsDomainFilter.kt`, `relay/TokenBucket.kt`, `relay/RelayTrafficPolicy.kt`, 대응 unit tests.

**Modify:** `network/CellularDnsForwarder.kt`, `relay/StreamBridge.kt`, 단계 2의 `UdpRelaySession.kt`, Android 설정 UI와 Mac metrics.

**계약:** DNS filter는 정규화한 이름을 메모리에서 label 경계로 비교한다. TokenBucket은 monotonic 시간과 byte budget을 받아 전송 가능 여부/대기 시간을 계산한다. 세션의 방향별 bucket을 flow들이 공유하며 engine/socket lock을 잡은 채 대기하지 않는다.

- [ ] DNS filter OFF, 대소문자·마지막 점, `example.test`와 `notexample.test` 구별, suffix, A/AAAA 차단 응답, malformed DNS를 시험한다. UI에 DNS 기반 필터의 한계와 업데이트 영향 표시를 넣는다.
- [ ] fake clock으로 burst 소진/보충, 긴 idle, 잘못된 설정, 동시 flow 공정성, 취소를 시험한다. TCP backpressure와 UDP datagram 원자성을 보존한다.
- [ ] burst budget이 허용하는 최대 datagram보다 작으면 설정을 거부한다. 다운로드 제한이 cellular 수신량 자체의 상한이라고 표시하지 않는다.
- [ ] OFF 회귀 후 제어된 부하로 rate/burst 오차, drop, p95 지연, 메모리, Stop 시간을 측정한다. 제어된 무손실 시험에서 초기 burst 이후 30초 평균 처리량은 설정률의 ±10%, 누적 허용 byte는 `설정률 × 경과시간 + burst budget` 이하여야 한다. 모바일 회선이 설정률보다 느린 경우 하한 판정에서 구별한다. 포화 시 기존 queue 한도를 넘지 않고 Stop은 3초 이내 완료해야 한다.
- [ ] MTU/MSS는 기본 1,280과 별도 비교한다. payload 상한·QUIC 1,200-byte Initial·단편화 정책을 깨는 값은 채택하지 않는다. 임의 clamp 대신 두 TCP 구간별 근거를 기록한다.
- [ ] UI에 설정/적용값, 현재 속도, UDP drop, 실패 원인을 표시한다. 사용자 payload와 DNS 이름은 기록하지 않는다.

## 4. IPv6·복구

기존 상세 계획: [dual-stack core](2026-09-21-droidbridge-b3-dual-stack-core-plan.md), [Android IPv6/ICMP](2026-09-21-droidbridge-b3-android-ipv6-icmp-plan.md), [macOS LAN/reconnect](2026-09-21-droidbridge-b3-macos-lan-reconnect-plan.md), [integration/release](2026-09-21-droidbridge-b3-integration-release-plan.md).

- [ ] NE 의존 경로를 단계 2.3의 CoreHost/helper 기준으로 교정하고 IPv6 TCP/UDP 합성·정책을 구현한다.
- [ ] IPv6 unavailable, dual-stack, IPv6-only/NAT64, Hop Limit 기본/지정/실패를 검증한다.
- [ ] ICMP Echo는 실제 기기 capability 범위에서 제공하고 미지원 상태를 표시한다.
- [ ] USB 재연결, Mac sleep/wake, cellular 교체 시 flow 정리와 새 연결 복구를 확인한다. 기존 QUIC 연결의 무중단 이동을 보장하지 않는다.
- [ ] LAN 예외는 기존 B3 명세의 선택형 범위로 검토하며 기본 fail-closed를 유지한다.
- [ ] B1/B2/프로필 회귀와 B3 8시간 mixed soak 후 안정 릴리스 후보를 만든다.

## 첫 작업과 완료 보고

첫 작업은 **PairingServerTest의 실제 포트 의존성 제거**다. 이후 간헐 TCP timeout과 남은 B1 실기기 gate를 처리한다. 각 단계 보고에는 변경 commit, 수행한 시험, 미실행 시험과 필요한 환경을 기록한다. 기능 구현·실기기 검증·배포 상태를 구별한다.
