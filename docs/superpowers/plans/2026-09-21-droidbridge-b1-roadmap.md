# DroidBridge B1 Delivery Roadmap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 승인된 B1 명세를 서로 독립적으로 검증 가능한 다섯 개의 구현 계획으로 나누고, Android LTE/5G를 Mac의 TCP 전체 터널 출구로 사용하는 DroidBridge B1을 순차적으로 완성한다.

**Architecture:** 먼저 DBP/1 와이어 형식과 공통 테스트 벡터를 고정한 뒤 Android loopback 릴레이를 완성한다. 그 위에 macOS ADB·페어링 제어면을 구축하고, 마지막으로 `NEPacketTunnelProvider`와 C/lwIP 데이터면을 연결한다. 최종 계획은 실기기 장애·누출·성능 검증과 운영 문서를 담당한다.

**Tech Stack:** C17, CMake/CTest, lwIP, Swift 6, SwiftUI, NetworkExtension, XcodeGen 2.46.0, Kotlin 2.4.20, Android Gradle Plugin 9.4.0, Gradle 9.6.0, Jetpack Compose, Kotlin Coroutines, Python 3.11+

**Spec:** `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`

## Global Constraints

- 대상은 Apple Silicon Mac, macOS 14 이상이다.
- Android 최소 버전은 8.0/API 26, compile/target SDK는 36이다.
- B1 데이터면은 IPv4, TCP, DNS만 지원한다. 일반 UDP, QUIC/HTTP3, IPv6, ICMP는 B1 범위 밖이다.
- Mac과 Android 사이의 전송은 USB ADB TCP forwarding을 사용한다.
- Android 루팅, macOS 커널 확장, TTL/Hop Limit·APN·DUN 변경을 금지한다.
- Android relay listener는 `127.0.0.1:27183`에만 바인딩한다.
- Pairing Secret은 macOS Keychain과 Android Keystore 보호 저장소에만 저장한다.
- Packet Tunnel 실행 중 relay 또는 cellular 장애가 발생하면 fail-closed 상태를 유지한다.
- 패킷 payload, HTTP URL, TLS SNI, 쿠키, 인증 헤더를 로그나 파일에 저장하지 않는다.
- 기본 최대 활성 TCP flow는 128, hard limit는 256이다.
- 터널 MTU는 B1에서 1280 bytes로 고정한다.
- 모든 외부 Android socket은 선택한 `TRANSPORT_CELLULAR` Network에 명시적으로 바인딩한다.
- 서드파티 코드는 BSD/MIT/Apache-2.0 호환 라이선스만 포함하고 버전 또는 gitlink를 고정한다.

## Review Focus

- USB가 연결 직후 또는 트래픽 중간에 분리될 때 macOS 기본 인터페이스로 조용히 우회하지 않고 차단 상태를 유지해야 한다.
- Android Wi-Fi가 켜져 있거나 기본 네트워크가 변경돼도 relay outbound socket은 셀룰러에만 바인딩돼야 한다.
- 도메인이 허용 IP와 차단 IP를 함께 반환하거나 DNS rebinding이 발생하면 실제 연결 IP를 다시 검사해 차단해야 한다.
- HMAC timestamp·nonce 재사용·잘린 DBP header·과대 payload가 서비스 크래시가 아니라 명시적 거부로 끝나야 한다.
- Packet Tunnel의 control connection이 자신의 기본 경로로 재진입해 routing loop를 만들지 않도록 `127.0.0.0/8` 제외와 health check를 검증해야 한다.

---

## 실행 순서

| 순서 | 계획 | 독립 완료 산출물 | 다음 계획이 소비하는 인터페이스 |
|---|---|---|---|
| 1 | `2026-09-21-droidbridge-foundation-protocol-plan.md` | 재현 가능한 저장소, DBP/1 문서·벡터, C codec/policy library, probe client | `protocol/test-vectors/dbp-v1.json`, C ABI, 오류 코드 |
| 2 | `2026-09-21-droidbridge-android-relay-plan.md` | 실제 Android에서 loopback DBP relay, cellular-bound TCP/DNS, Compose UI | `HELLO`, `OPEN_TCP`, `DNS_QUERY`, health endpoint |
| 3 | `2026-09-21-droidbridge-macos-control-plane-plan.md` | 메뉴바 앱, ADB 관리, P-256 pairing, Keychain, relay health | App Group runtime config, `RelayControlClient` |
| 4 | `2026-09-21-droidbridge-packet-tunnel-plan.md` + `2026-09-22-droidbridge-utun-helper-app.md` | C/lwIP TCP bridge, virtual DNS, signed utun helper, pf fail-closed data plane | 완전한 B1 tunnel runtime |
| 5 | `2026-09-21-droidbridge-integration-release-plan.md` | 실기기 수용 시험, 누출·장애·성능 검증, 운영·위협 모델 문서 | B1 debug/release artifact |

## 실행 체크포인트

- [x] **Phase 1 — Foundation:** DBP/1 fixture, C codec/policy, probe와 foundation gate를 통과한다.
- [x] **Phase 2 — Android Relay:** 실제 Android에서 pairing, cellular-bound TCP/DNS, loopback relay smoke를 통과한다.
- [x] **Phase 3 — macOS Control Plane:** signed HostApp으로 ADB, pairing, Keychain, authenticated health를 검증한다.
- [x] **Phase 4 — Full Tunnel:** C/lwIP data plane, signed utun helper, DNS bridge와 fail-closed build/check gate를 통과한다. 실제 root/device 동작은 Phase 5에서 검증한다.
- [ ] **Phase 5 — Acceptance:** 실제 기기에서 14개 수용 기준, 1시간 soak, 성능·누출 검증 후에만 `v0.1.0-b1`을 만든다.

## 계획 간 고정 인터페이스

### DBP/1 TCP session

```text
TCP connect to 127.0.0.1:27183
  -> HELLO (64-byte header, no payload)
  <- HELLO_OK
  -> OPEN_TCP (header + destination payload)
  <- OPEN_OK
  <-> raw application byte stream
```

각 TCP flow는 별도 DBP/1 connection을 사용한다. `OPEN_OK` 이후에는 framing 없이 raw stream으로 전환하며, 같은 socket에 추가 DBP control message를 섞지 않는다.

### DNS session

```text
TCP connect to 127.0.0.1:27183
  -> HELLO
  <- HELLO_OK
  -> DNS_QUERY (header + 2-byte length + DNS wire packet)
  <- DNS_RESPONSE (header + 2-byte length + DNS wire packet)
  -> connection close
```

### Runtime configuration shared through App Group

```swift
struct TunnelRuntimeConfiguration: Codable, Equatable {
    let deviceSerial: String
    let relayHost: String       // always "127.0.0.1"
    let relayPort: UInt16       // always 27183 for B1
    let pairedPeerId: String
    let keychainAccount: String
    let maximumFlows: UInt16    // default 128, max 256
}
```

Pairing Secret 자체는 App Group 파일에 기록하지 않는다. Packet Tunnel extension은 `keychainAccount`로 shared access-group Keychain item을 읽는다.

### Fail-closed state model

```swift
enum TunnelRuntimeState: String, Codable {
    case disconnected
    case preparing
    case connected
    case blockedRelayUnavailable
    case blockedCellularUnavailable
    case reconnecting
    case disconnecting
    case failed
}
```

`blocked*`와 `reconnecting` 상태에서는 `NEPacketTunnelNetworkSettings`를 제거하지 않고 packetFlow에서 읽은 인터넷 패킷을 폐기한다.

## 실행 게이트

- 각 하위 계획은 자신의 전체 test command가 통과한 뒤에만 다음 계획으로 넘어간다.
- 각 Task는 실패 테스트 작성 → 실패 확인 → 최소 구현 → 통과 확인 → 커밋 순서를 지킨다.
- 실기기 전용 검증은 자동화 가능한 부분과 수동 확인 부분을 명령·예상 결과로 함께 기록한다.
- 서명·entitlement 때문에 Packet Tunnel을 실제 실행할 수 없는 환경에서는 unit test까지만 통과했다고 명시하고 B1 완료로 선언하지 않는다.
- 마지막 계획의 14개 명세 수용 기준을 모두 확인하기 전에는 `v0.1.0-b1` 태그를 생성하지 않는다.
