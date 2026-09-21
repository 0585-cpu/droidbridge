# DroidBridge B1–B3 Delivery Roadmap

> **For agentic workers:** 각 단계는 선행 release gate를 통과한 뒤에만 진행한다. 구현 시 `superpowers:subagent-driven-development` 또는 `superpowers:executing-plans`를 사용하고, 각 계획의 체크박스를 task-by-task로 추적한다.

**Goal:** Android LTE/5G를 Mac의 fail-closed full-tunnel 출구로 사용하는 DroidBridge를 B1 IPv4/TCP에서 B2 IPv4/UDP·QUIC, B3 dual-stack·복구 안정화까지 순차적으로 완성한다.

**Architecture:** B1은 IPv4/TCP와 DNS를 검증한다. B2는 기존 flow별 relay 모델을 UDP datagram으로 확장한다. B3는 공통 address-family 모델, IPv6, capability 기반 ICMP, LAN route exception, event/reconnect state machine을 추가한다.

**Tech Stack:** C17, CMake/CTest/libFuzzer, lwIP, Swift 6, SwiftUI, NetworkExtension, Network.framework, Kotlin, Android NDK, Jetpack Compose, Coroutines, Python 3.11+

**Specs:**

- `docs/superpowers/specs/2026-09-21-droidbridge-full-tunnel-design.md`
- `docs/superpowers/specs/2026-09-21-droidbridge-b2-udp-quic-design.md`
- `docs/superpowers/specs/2026-09-21-droidbridge-b3-dual-stack-resilience-design.md`

## Global Constraints

- Apple Silicon, macOS 14 이상.
- Android API 26 이상, root 불필요.
- transport는 B3까지 USB ADB TCP forwarding.
- Android relay listener는 loopback에만 bind.
- 모든 Android outbound socket은 selected cellular `Network`에 명시적으로 bind.
- blocked/reconnecting 상태에서 IPv4/IPv6 route를 제거하지 않는다.
- explicit Disconnect만 기본 macOS route를 복원한다.
- payload, DNS name, secret, SNI, URL을 로그·evidence에 저장하지 않는다.
- TTL/Hop Limit, APN, DUN, carrier 식별값을 변경하지 않는다.
- private/internal destination policy를 protocol family별로 적용한다.

## Release Map

| 단계 | 태그 | 기능 | 완료 gate |
|---|---|---|---|
| B1 | `v0.1.0-b1` | IPv4 TCP, DNS, fail-closed | 기존 14개 acceptance |
| B2 | `v0.2.0-b2` | IPv4 UDP, QUIC/HTTP3 | B2 14개 acceptance + B1 regression |
| B3 | `v0.3.0-b3` | IPv6 TCP/UDP, ICMP Echo, LAN bypass, reconnect | B3 20개 acceptance + B1/B2 regression |
| Stable | `v1.0.0` | B3 동일 기능의 안정화 build | 동일 commit 재현 빌드·8시간 soak·manifest 서명 |

## Detailed Plans

### B1

1. `2026-09-21-droidbridge-foundation-protocol-plan.md`
2. `2026-09-21-droidbridge-android-relay-plan.md`
3. `2026-09-21-droidbridge-macos-control-plane-plan.md`
4. `2026-09-21-droidbridge-packet-tunnel-plan.md`
5. `2026-09-21-droidbridge-integration-release-plan.md`

### B2

1. `2026-09-21-droidbridge-b2-protocol-udp-core-plan.md`
2. `2026-09-21-droidbridge-b2-android-udp-relay-plan.md`
3. `2026-09-21-droidbridge-b2-macos-udp-quic-plan.md`
4. `2026-09-21-droidbridge-b2-integration-release-plan.md`

### B3

1. `2026-09-21-droidbridge-b3-dual-stack-core-plan.md`
2. `2026-09-21-droidbridge-b3-android-ipv6-icmp-plan.md`
3. `2026-09-21-droidbridge-b3-macos-lan-reconnect-plan.md`
4. `2026-09-21-droidbridge-b3-integration-release-plan.md`

## Dependency DAG

```text
B1 protocol -> B1 Android -> B1 control -> B1 packet tunnel -> B1 acceptance
                                                               │
                                                               ▼
B2 DBP/UDP core -> B2 Android UDP -> B2 macOS UDP/QUIC -> B2 acceptance
                                                               │
                                                               ▼
B3 dual-stack core -> B3 Android IPv6/ICMP -> B3 macOS LAN/reconnect -> B3 acceptance -> v1.0.0
```

## Cross-release Interface Rules

1. DBP header magic와 64-byte base header는 B1–B3에서 유지한다.
2. 새로운 기능은 capability 확인 뒤 사용한다.
3. unknown message, flag, address family는 명시적 protocol error다.
4. B1 client와 B1 relay 조합은 B2/B3 코드베이스에서도 계속 동작해야 한다.
5. Packet Tunnel settings 업데이트는 atomic하게 적용하고 실패 시 더 넓은 bypass가 아니라 더 강한 차단으로 돌아간다.
6. test vector는 Python generator가 canonical source이며 C/Kotlin/Swift가 동일 fixture를 소비한다.

## Gate Checklist

### B1 Gate

- [ ] IPv4 TCP/DNS functional acceptance PASS
- [ ] USB/cellular fail-closed PASS
- [ ] 128 TCP flows, 1-hour soak PASS
- [ ] `v0.1.0-b1` reproducible package PASS

### B2 Gate

- [ ] B1 regression PASS
- [ ] IPv4 UDP echo and 1,232-byte payload PASS
- [ ] QUIC/HTTP3 controlled endpoint PASS
- [ ] 100 concurrent UDP flows PASS
- [ ] 2-hour TCP/UDP soak PASS
- [ ] private destination and malformed frame suite PASS
- [ ] `v0.2.0-b2` manifest PASS

### B3 Gate

- [ ] B1/B2 regression PASS
- [ ] IPv6 TCP/UDP controlled endpoint PASS
- [ ] IPv6 unavailable leak test PASS
- [ ] NAT64 policy PASS
- [ ] ICMP capability/echo test PASS
- [ ] LAN bypass exact-route test PASS
- [ ] USB/sleep/cellular reconnect matrix PASS
- [ ] 8-hour mixed soak PASS
- [ ] `v0.3.0-b3` manifest PASS
- [ ] same-commit stable gate and `v1.0.0` PASS

## Execution Policy

- 각 task는 failing test → failure 확인 → 최소 구현 → 전체 관련 test → commit 순서를 따른다.
- 실기기 전용 acceptance가 실패하면 unit test 성공만으로 release를 생성하지 않는다.
- Network Extension entitlement나 signing이 없는 환경에서는 문서·unit artifact만 만들고 full release 완료로 표시하지 않는다.
- Android 기기별 ICMP capability 차이는 숨기지 않고 manifest에 실제 결과를 기록한다.
- LAN bypass는 security review가 완료되기 전 default-on으로 변경하지 않는다.
