# DroidBridge B3 Dual-Stack, ICMP, LAN Policy, and Resilience 설계 확장 명세

- 문서 상태: B1/B2 승인 설계를 확장하는 B3 구현 기준
- 작성일: 2026-09-21
- 대상 릴리스: `v0.3.0-b3`, 안정화 태그 `v1.0.0`
- 선행 조건: B1과 B2 수용 기준 전체 통과
- 프로젝트명: DroidBridge

## 1. 목적

B3는 DroidBridge를 IPv4-only 도구에서 **fail-closed dual-stack reverse tethering 도구**로 확장한다. IPv6 TCP/UDP, 제한된 ICMP echo, 명시적 LAN 예외, USB·sleep·cellular handover 복구를 추가하고 B1/B2 기능을 안정화한다.

B3도 Android 루팅, macOS kernel extension, TTL/Hop Limit 조작, APN/DUN 변조, 통신사 과금·쿼터 우회 기능을 포함하지 않는다.

## 2. 범위

### 2.1 포함

- macOS Packet Tunnel의 `::/0` 포함 route
- IPv6 TCP와 UDP
- IPv6 destination policy
- NAT64 prefix 인지 및 embedded IPv4 정책 검사
- Android cellular IPv6 capability 탐지
- ICMPv4/ICMPv6 echo proxy의 capability 기반 지원
- UDP network migration
- cellular handover event
- USB ADB 자동 재연결
- sleep/wake 복구
- 선택적 현재 LAN subnet bypass
- LAN bypass UI 경고와 route preview
- dual-stack DNS 응답 정책
- 8시간 mixed soak와 안정화 릴리스

### 2.2 제외

- arbitrary raw ICMP forwarding
- traceroute용 모든 ICMP error 전달
- IPv6 fragmentation 재조립
- Mobile IPv6
- TCP connection migration 또는 session resumption
- custom arbitrary CIDR LAN bypass
- Wi-Fi Direct/USB accessory transport
- Always-On VPN/MDM 수준의 OS 강제 정책

## 3. Dual-stack 아키텍처

```text
macOS IPv4/IPv6 applications
          │
          ▼
NEPacketTunnelProvider
  ├─ IPv4 198.18.0.2/30, route 0.0.0.0/0
  └─ IPv6 fd7d:6272:6964::2/126, route ::/0
          │
          ▼
C dual-stack packet core
  ├─ TCP4/TCP6 via lwIP
  ├─ UDP4/UDP6 via datagram engine
  ├─ ICMP echo request extraction
  ├─ DNS A/AAAA policy
  └─ IPv4/IPv6 destination policy
          │
          ▼
DBP/1.2 relay flows over ADB
          │
          ▼
Android cellular relay
  ├─ Socket/DatagramSocket bound to Network
  ├─ IPv6 literals and resolved addresses
  ├─ NAT64 prefix/capability reporting
  ├─ ICMP ping socket capability probe
  └─ network generation events
          │
          ▼
LTE/5G dual-stack network
```

## 4. macOS virtual addressing과 route

```text
IPv4 interface: 198.18.0.2/30
IPv4 gateway/DNS: 198.18.0.1
IPv6 interface: fd7d:6272:6964::2/126
IPv6 gateway/DNS: fd7d:6272:6964::1
MTU: 1280
```

B3에서는 Android cellular IPv6가 없더라도 `::/0`을 Packet Tunnel에 포함한다. literal IPv6 또는 stale AAAA 트래픽이 physical interface로 빠져나가는 것을 방지하기 위해서다. Android가 IPv6 unavailable을 보고하면 IPv6 packet은 fail-closed drop하고 DNS bridge는 AAAA를 NODATA로 변환한다.

## 5. DBP/1.2 확장

### 5.1 신규 address type

```text
1 IPv4
2 IPv6
3 domain
```

`OPEN_TCP`와 `OPEN_UDP`는 address type 2일 때 length 16의 network-order IPv6 주소를 사용한다.

### 5.2 capability bitset

`HEALTH_RESPONSE`에 64-bit capability field를 추가한 canonical variant를 정의한다. B1/B2 fixed payload를 구분하기 위해 payload version byte를 선두에 둔다.

```text
bit 0 TCP4
bit 1 UDP4
bit 2 TCP6
bit 3 UDP6
bit 4 ICMP4_ECHO
bit 5 ICMP6_ECHO
bit 6 NAT64_PREFIX
bit 7 NETWORK_EVENTS
bit 8 UDP_REBIND
```

### 5.3 network generation

health/event payload에는 monotonic `network_generation` 64-bit 값을 포함한다. Android가 selected cellular `Network`를 교체할 때마다 증가한다.

### 5.4 Event channel

신규 message type:

```text
0x50 SUBSCRIBE_EVENTS
0x51 EVENT_NETWORK_CHANGED
0x52 EVENT_CAPABILITIES_CHANGED
0x53 EVENT_RELAY_STOPPING
```

각 event는 공통 DBP header와 HMAC을 사용한다. event channel은 control-only connection이며 raw stream 모드로 전환하지 않는다.

### 5.5 ICMP echo message

```text
0x60 ICMP_ECHO_REQUEST
0x61 ICMP_ECHO_RESPONSE
0x62 ICMP_ECHO_ERROR
```

request payload:

```text
1 byte   family: 4 or 6
1 byte   hop limit/TTL
2 bytes  payload length: 0...1200
4 bytes  request id
16 bytes destination slot; IPv4는 첫 4 bytes 사용 후 12 bytes zero
N bytes  echo payload
```

response payload:

```text
4 bytes  request id
1 byte   family
1 byte   received TTL/hop limit, 0 if unavailable
2 bytes  payload length
8 bytes  round-trip microseconds
16 bytes source address slot
N bytes  payload
```

Mac의 원래 ICMP identifier/sequence는 packet core가 `request id`와 매핑한다. Android kernel ping socket이 identifier를 변경하더라도 Mac 응답 packet에는 원래 값을 복원한다.

## 6. IPv6 packet core

### 6.1 Parser limits

- base header 40 bytes
- payload length와 buffer 일치
- next-header chain 최대 4개
- extension header 총 길이 최대 256 bytes
- Hop-by-Hop, Destination Options는 bounded skip
- Routing Header type 0은 거부
- Fragment Header는 atomic fragment만 허용; non-zero offset 또는 M flag는 drop
- TCP, UDP, ICMPv6만 dispatch
- unknown next-header는 drop metric

### 6.2 Checksum

TCP6, UDP6, ICMPv6는 IPv6 pseudo-header checksum을 검증·생성한다. UDP6 checksum 0은 invalid다.

### 6.3 Flow key

주소 family와 16-byte canonical address를 공통 key로 사용한다.

```c
struct db_ip_address {
    uint8_t family;
    uint8_t bytes[16];
};

struct db_flow_key {
    struct db_ip_address source;
    uint16_t source_port;
    struct db_ip_address destination;
    uint16_t destination_port;
    uint8_t protocol;
};
```

IPv4는 4 bytes 후 12 bytes zero이며 IPv4-mapped IPv6 형식으로 저장하지 않는다.

## 7. IPv6 목적지 정책

기본 차단:

```text
::/128                 unspecified
::1/128                loopback
::ffff:0:0/96          IPv4-mapped
64:ff9b:1::/48         local-use NAT64 unless reported by Android
100::/64               discard-only
2001:2::/48            benchmarking
2001:db8::/32          documentation
2001:10::/28           ORCHIDv1
2001:20::/28           ORCHIDv2
fc00::/7               unique local
fe80::/10              link local
ff00::/8               multicast
```

Android가 `LinkProperties.getNat64Prefix()`로 보고한 NAT64 prefix는 예외적으로 허용할 수 있다. 단, synthesized address에서 embedded IPv4를 추출할 수 있을 때 B1 IPv4 destination policy를 적용하며 private/loopback/link-local IPv4를 encode한 address는 차단한다.

## 8. Android IPv6 transport

- `Network.getSocketFactory().createSocket()`과 `DatagramSocket` bind는 IPv4/IPv6 모두 지원한다.
- address type 2는 DNS 재해석 없이 literal `Inet6Address`로 연결한다.
- domain flow는 `Network.getAllByName()` 결과를 address family별 정책 검사 후 시도한다.
- `LinkProperties`에서 global IPv6 address, DNS server, NAT64 prefix를 수집한다.
- Wi-Fi/default network fallback은 금지한다.

## 9. ICMP 지원 경계

일반 Android 앱은 모든 기기에서 raw ICMP socket을 보장받지 못한다. B3는 다음 capability 기반 모델을 고정한다.

1. NDK helper가 `SOCK_DGRAM + IPPROTO_ICMP/IPPROTO_ICMPV6` ping socket을 시도한다.
2. socket을 `android_setsocknetwork()`로 selected cellular network에 바인딩한다.
3. 성공한 family만 health capability에 노출한다.
4. 지원되지 않으면 Mac UI에 명확히 표시하고 echo request에 local unreachable을 반환한다.
5. subprocess `ping` 호출이나 root 권한을 사용하지 않는다.
6. 성공하지 않은 ping을 성공으로 합성하지 않는다.

B3의 ICMP 범위는 Echo Request/Reply와 packet core가 자체 생성하는 오류다. arbitrary ICMP redirect, router advertisement, neighbor discovery를 relay하지 않는다.

## 10. DNS dual-stack 정책

- Android IPv6 available: A/AAAA 응답을 그대로 전달하되 destination policy에 위배되는 record를 제거한다.
- Android IPv6 unavailable: AAAA query는 valid NODATA response로 변환한다.
- HTTPS/SVCB record의 `ipv6hint`는 IPv6 unavailable일 때 제거한다.
- A record와 `ipv4hint`는 유지한다.
- DNSSEC-signed response를 수정해야 하는 경우 validation을 깨뜨릴 수 있으므로 해당 response는 SERVFAIL로 처리하고 metric을 기록한다.
- DNS payload나 query name은 로그에 기록하지 않는다.

## 11. 선택적 LAN bypass

### 11.1 기본값

`LANAccessMode.denyAll`이며 B1/B2와 동일하게 local route를 제외하지 않는다.

### 11.2 허용 모드

사용자가 HostApp에서 **현재 연결된 LAN만 허용**을 선택하면 다음 route만 후보가 된다.

- physical Wi-Fi/Ethernet에 직접 연결된 RFC1918 IPv4 subnet
- 직접 연결된 IPv6 ULA `/64`
- IPv4 link-local `/16`과 IPv6 link-local `/64`은 별도 `Allow discovery protocols` toggle이 켜진 경우만
- mDNS multicast `224.0.0.251/32`, `ff02::fb/128`은 discovery toggle에서만

거부 규칙:

- IPv4 prefix가 `/16`보다 넓으면 자동 제외하지 않는다.
- public IPv4/IPv6 prefix를 제외하지 않는다.
- default route를 제외하지 않는다.
- arbitrary custom CIDR 입력을 제공하지 않는다.

HostApp은 적용 전 정확한 CIDR 목록과 “이 트래픽은 Android가 아니라 현재 LAN으로 직접 전송된다”는 경고를 보여준다.

### 11.3 동적 변경

physical interface route가 변경되면 후보를 다시 계산한다. settings 갱신 실패 시 LAN bypass를 제거하고 full fail-closed route로 복귀한다.

## 12. 자동 복구

### 12.1 ADB transport

HostApp은 `adb track-devices -l`을 장기 실행한다. 선택된 serial의 상태 변화를 수신하면 다음을 수행한다.

```text
offline/detached
  -> Packet Tunnel blockedTransport
  -> existing TCP/UDP flows close
  -> keep IPv4/IPv6 tunnel routes installed
  -> retry 1,2,4,8,15 seconds
  -> after 5 failures retry every 30 seconds

device returns
  -> recreate owned forwards
  -> authenticated health
  -> capability/network generation check
  -> resume accepting new flows
```

사용자가 Disconnect를 누르기 전에는 기본 route를 복원하지 않는다.

### 12.2 Cellular handover

- new `Network` selected → generation increment
- TCP flows bound to old network → reset; application reconnects
- UDP flows → 새 network-bound socket으로 rebind하고 flow tuple 유지
- QUIC은 NAT rebinding을 스스로 처리할 수 있도록 datagram stream을 유지
- rebind 실패 flow만 종료

### 12.3 Sleep/wake

wake event에서 ADB, forward ownership, relay health, network generation을 재검증한다. 검증 완료 전 packet을 drop한다.

## 13. UI와 상태

추가 상태:

```text
connectedDualStack
connectedIPv4Only
blockedTransport
blockedCellular
reconnectingTransport
reconfiguringRoutes
icmpPartiallyAvailable
lanBypassActive
```

메뉴바에 다음을 표시한다.

- Android device와 carrier
- IPv4/IPv6 capability
- ICMP4/ICMP6 capability
- active TCP/UDP flows
- current LAN bypass CIDR
- transport reconnect attempt
- dropped packet counters

## 14. Fail-closed 규칙

- IPv4/IPv6 routes는 blocked/reconnecting 동안 유지한다.
- relay capability가 불명확하면 해당 family를 drop한다.
- LAN bypass는 사용자가 명시적으로 켠 route에만 적용한다.
- route 갱신 실패 시 bypass보다 차단을 우선한다.
- event channel이 끊어지면 health poll로 downgrade하고, 둘 다 실패하면 blocked 상태다.
- Network Extension 강제 종료와 OS 재부팅은 일반 앱 수준에서 완전한 always-on 보장을 하지 않는다.

## 15. 성능·안정성 목표

- IPv6 TCP throughput: B2 IPv4 TCP의 80% 이상
- IPv6 UDP throughput: 12 Mbps 이상
- dual-stack DNS median latency overhead: 30 ms 이하
- USB 60초 분리 후 재연결: device return 후 10초 이내 신규 flow 성공
- sleep 10분 후 wake: 15초 이내 신규 flow 성공
- UDP handover: QUIC connection이 지원 환경에서 10초 내 복구
- 8시간 mixed soak 동안 crash 0, leaked flow 0, unbounded memory growth 없음

## 16. B3 수용 기준

1. B1/B2 수용 기준 전체 재통과.
2. IPv6 TCP HTTPS와 SSH가 Android cellular IPv6를 통해 동작.
3. IPv6 UDP echo와 QUIC가 동작.
4. Android IPv6 unavailable일 때 Mac IPv6가 physical interface로 누출되지 않음.
5. AAAA NODATA policy가 정상 적용됨.
6. NAT64 prefix 사용 시 embedded private IPv4가 차단됨.
7. ICMP4/ICMP6 capability가 실제 socket 결과와 일치함.
8. 지원 기기에서 ping reply가 원래 identifier/sequence로 복원됨.
9. 미지원 기기에서 성공을 위조하지 않고 명시적 unavailable 처리.
10. LAN bypass off에서 local LAN 접근이 차단됨.
11. LAN bypass on에서 표시된 current subnet만 직접 접근 가능.
12. public/default route는 bypass 목록에 들어가지 않음.
13. USB detach 동안 IPv4/IPv6 모두 fail-closed.
14. USB return 후 사용자 재클릭 없이 신규 flow 복구.
15. cellular handover 후 신규 TCP와 기존 QUIC/UDP가 정의된 동작을 보임.
16. sleep/wake 복구 성공.
17. 8시간 mixed soak 통과.
18. privacy artifact에 payload, DNS name, secret이 없음.
19. `v0.3.0-b3` acceptance manifest가 전부 PASS.
20. 같은 commit에서 stable regression gate를 재실행한 뒤 `v1.0.0` 생성.

## 17. 구현 순서

1. DBP/1.2 capability/IPv6/ICMP fixture
2. C IPv6 parser/checksum/policy
3. dual-stack TCP/UDP engine
4. Android IPv6 socket/capability
5. Android ICMP NDK helper
6. macOS dual-stack settings/packet integration
7. LAN bypass policy와 UI
8. event channel/ADB reconnect/sleep-wake
9. dual-stack·fault·soak acceptance

## 18. 고정 결정

- IPv6 virtual prefix는 `fd7d:6272:6964::/126`이다.
- MTU는 1,280을 유지한다.
- IPv6 route는 Android IPv6 unavailable 상태에서도 tunnel에 포함해 leak을 막는다.
- non-atomic IPv6 fragment는 지원하지 않는다.
- ICMP는 capability 기반 Echo만 지원한다.
- root와 external `ping` subprocess는 사용하지 않는다.
- LAN bypass는 current directly-connected subnet만 제공한다.
- TCP session migration은 지원하지 않는다.
- UDP는 cellular handover 시 rebind를 시도한다.
- TTL/APN/DUN과 carrier detection evasion은 구현하지 않는다.
