# DroidBridge B2 UDP/QUIC 설계 확장 명세

> 2026-09-23 전송 변경: [AOA 설계](../specs/2026-09-23-droidbridge-aoa-design.md)가 이 문서의 ADB 제품 경로를 대체한다.
> **2026-09-23 보충:** [설계 보충](2026-09-23-droidbridge-udp-traffic-profile-design.md)의 helper 통합, 현재 DNS interception 보존 및 B2 이후 선택형 TTL·트래픽 프로필 범위가 이 문서의 관련 설명보다 우선한다.

- 문서 상태: B1 승인 명세를 확장하는 B2 구현 기준
- 작성일: 2026-09-21
- 대상 릴리스: `v0.2.0-b2`
- 선행 조건: B1 `v0.1.0-b1` 수용 기준 전체 통과
- 프로젝트명: DroidBridge

## 1. 목적

B2는 B1의 IPv4/TCP 전체 터널에 **일반 IPv4 UDP 전달**을 추가한다. 목표는 macOS 애플리케이션이 별도 프록시 설정 없이 DNS 이외의 UDP, QUIC/HTTP3, 실시간 음성·영상 및 게임형 UDP 트래픽을 Android LTE/5G를 통해 사용할 수 있게 하는 것이다.

B2는 B1의 보안 경계와 fail-closed 동작을 유지한다. TTL/Hop Limit, APN, DUN 또는 통신사 식별값을 변경하거나 통신사 과금·쿼터 회피를 보장하는 기능은 포함하지 않는다.

## 2. 범위

### 2.1 포함

- IPv4 UDP 전체 터널
- QUIC/HTTP3 트래픽
- UDP echo 및 일반 request/response 트래픽
- flow별 datagram 경계 보존
- Android 셀룰러 `Network`에 바인딩된 `DatagramSocket`
- 최대 1,232-byte UDP payload
- UDP flow idle timeout, backpressure, queue drop 정책
- B1 DNS bridge 유지
- B1 TCP와 UDP 동시 사용
- fail-closed 장애 처리
- UDP/QUIC 기능·보안·성능 수용 시험

### 2.2 제외

- IPv6 UDP와 IPv6 TCP: B3
- 원시 ICMP forwarding: B3 제한 지원
- IPv4 fragmentation 재조립
- UDP GSO/GRO
- ADB 비의존 USB transport
- 임의 LAN 또는 Android 내부망 접근
- UDP payload 저장·검사·복호화

## 3. 고정 아키텍처

```text
macOS application
      │ IPv4 UDP packet
      ▼
NEPacketTunnelProvider.packetFlow
      │
      ▼
C db_udp_engine
  ├─ IPv4/UDP validation
  ├─ 5-tuple flow lookup
  ├─ checksum verification
  ├─ fragment rejection
  └─ datagram callback
      │
      ▼
Swift UDPSessionManager
      │ one authenticated relay TCP connection per UDP flow
      ▼
DBP/1.1 OPEN_UDP + datagram frames
      │ USB / adb forward
      ▼
Android UdpRelaySession
      │ Network.bindSocket(DatagramSocket)
      ▼
LTE / 5G UDP socket
      │
      ▼
Internet
```

B2는 **UDP flow 하나당 DBP relay TCP connection 하나**를 사용한다. 하나의 다중화 연결에 모든 UDP flow를 넣지 않는다. USB 구간의 단일 connection 손실이 모든 UDP flow를 동시에 막는 것을 피하고, B1의 flow별 격리 모델을 유지하기 위한 결정이다.

ADB 자체가 TCP transport이므로 완전한 비신뢰·고손실 구간용 QUIC transport와 같은 손실 특성을 제공하지 않는다. B2의 transport 전제는 짧고 안정적인 USB 연결이다.

## 4. DBP/1.1 프로토콜 확장

### 4.1 버전 호환

- 공통 magic과 64-byte header는 `DBP1`을 유지한다.
- B1 message type과 encoding은 변경하지 않는다.
- B2 client는 `HEALTH_RESPONSE`의 capability bitset을 확인한 뒤 `OPEN_UDP`를 사용한다.
- B1 relay가 capability를 제공하지 않으면 UDP를 시작하지 않고 TCP-only 상태를 표시한다.

### 4.2 신규 message type

```text
0x40 OPEN_UDP
0x41 OPEN_UDP_OK
0x42 OPEN_UDP_ERROR
0x43 UDP_CLOSE
```

### 4.3 OPEN_UDP payload

```text
1 byte   address type: 1=IPv4
2 bytes  destination port, network byte order
1 byte   address length: exactly 4
4 bytes  destination IPv4 address
2 bytes  requested idle timeout seconds: 30...300
```

B2에서는 domain 형태의 `OPEN_UDP`를 허용하지 않는다. Mac packet flow가 이미 IP 목적지를 포함하므로 Android DNS 재해석이 필요하지 않다. virtual DNS `198.18.0.1:53`은 기존 B1 DNS bridge가 처리한다.

### 4.4 OPEN_UDP_OK payload

```text
4 bytes  server flow id
2 bytes  effective idle timeout seconds
2 bytes  maximum datagram payload: 1232
```

### 4.5 OPEN_UDP_ERROR payload

```text
2 bytes  DBP error code
2 bytes  platform errno category
```

B2 신규 오류 코드:

```text
10 UDP_UNSUPPORTED
11 DATAGRAM_TOO_LARGE
12 UDP_IDLE_TIMEOUT
13 UDP_QUEUE_OVERFLOW
14 ADDRESS_FAMILY_UNAVAILABLE
```

### 4.6 Datagram stream frame

`OPEN_UDP_OK` 이후 같은 TCP connection은 다음 frame의 연속으로 전환한다.

```text
Offset  Size  Field
0       2     payload length, 0...1232
2       1     flags: bit0=REMOTE_TO_MAC, bit1=QUEUE_DROP_NOTICE
3       1     reserved, must be zero
4       4     sequence, unsigned network byte order
8       N     datagram payload
```

규칙:

- frame length가 1,232를 초과하면 connection을 닫고 `DATAGRAM_TOO_LARGE`를 기록한다.
- sequence는 방향별로 0부터 시작해 wrap을 허용한다.
- sequence gap은 손실 지표로만 사용하며 재전송을 요구하지 않는다.
- TCP가 이미 전송 무결성과 순서를 제공하므로 frame별 HMAC이나 CRC는 추가하지 않는다.
- payload는 로그에 기록하지 않는다.

## 5. macOS UDP packet core

### 5.1 패킷 처리

`db_udp_engine`은 다음을 검증한다.

- IPv4 version과 IHL
- total length와 packet buffer 일치
- protocol 17
- header checksum
- fragment offset 0, MF flag 0
- UDP length 8...1,240
- UDP checksum이 0이 아니면 pseudo-header checksum 검증
- 목적지 정책

fragmented packet은 재조립하지 않고 drop metric을 증가시킨다. Packet Tunnel MTU는 1,280을 유지하므로 정상 애플리케이션은 fragment를 만들지 않아야 한다.

### 5.2 Flow key

```c
struct db_udp_flow_key_v4 {
    uint32_t source_address;
    uint16_t source_port;
    uint32_t destination_address;
    uint16_t destination_port;
};
```

flow는 양방향 5-tuple로 식별한다. 동일 source port가 서로 다른 destination에 사용되면 별도 flow다.

### 5.3 Response synthesis

Android에서 받은 datagram은 원래 flow tuple을 반대로 적용해 IPv4/UDP packet으로 합성한다.

- source = 원래 destination
- destination = 원래 source
- source port = 원래 destination port
- destination port = 원래 source port
- IPv4 ID는 cryptographically random이 아닌 monotonic 16-bit counter 사용
- DF bit 설정
- IPv4 header checksum 계산
- UDP checksum 계산; 계산 결과 0이면 wire value `0xffff` 사용

### 5.4 Resource limits

- default active UDP flows: 128
- hard active UDP flows: 256
- TCP+UDP total hard limit: 512
- per-flow outbound queue: 64 datagrams 또는 256 KiB 중 먼저 도달한 값
- per-flow inbound queue: 동일
- queue overflow: 가장 오래된 datagram을 drop하고 최신 datagram을 유지
- default idle timeout: 120초
- cleanup sweep: 5초

실시간 트래픽은 오래된 datagram보다 최신 datagram의 가치가 높으므로 `drop-oldest`를 고정한다.

## 6. Android UDP relay

### 6.1 Socket 생성 순서

```text
DatagramSocket(null)
  -> cellularNetwork.bindSocket(socket)
  -> socket.connect(destination)
  -> socket.soTimeout = 1000 ms
  -> send/receive loop
```

`bindSocket` 또는 `connect`가 실패하면 Wi-Fi나 default network로 fallback하지 않는다.

### 6.2 Coroutine model

각 `UdpRelaySession`은 세 coroutine으로 구성한다.

1. DBP frame reader → outbound bounded channel
2. outbound channel → cellular socket send
3. cellular socket receive → DBP frame writer

session scope가 취소되면 socket과 relay connection을 닫고 세 coroutine을 모두 join한다.

### 6.3 Network 변경

B2에서는 선택된 cellular `Network`가 사라지면 해당 UDP session을 종료한다. 새 cellular `Network`에서 기존 UDP flow를 투명하게 재생성하는 기능은 B3에서 추가한다.

## 7. DNS 처리

B2에서도 macOS DNS server는 `198.18.0.1`이다. 목적지가 이 주소의 UDP/TCP 53인 패킷은 일반 UDP engine으로 보내지 않고 B1 DNS bridge가 처리한다.

이 결정을 유지하는 이유:

- Android가 선택한 cellular DNS server를 사용한다.
- DNS UDP→TCP fallback을 유지한다.
- DNS transaction과 일반 UDP flow 수명주기를 분리한다.
- DNS를 arbitrary public resolver로 강제하지 않는다.

## 8. 목적지 정책

B1 IPv4 차단 정책을 UDP에도 동일하게 적용한다. 특히 다음은 계속 차단한다.

- loopback
- RFC1918
- carrier-grade NAT `100.64.0.0/10`
- link-local
- benchmark/documentation ranges
- multicast/broadcast
- Android cellular interface의 local gateway 및 DNS server에 대한 일반 UDP 접근

virtual DNS bridge만 선택된 cellular DNS server와 통신할 수 있다.

## 9. Fail-closed와 오류 처리

| 사건 | B2 동작 |
|---|---|
| relay/USB 손실 | 모든 UDP flow 종료, Packet Tunnel 유지, 패킷 drop |
| cellular loss | Android UDP socket 닫기, Mac blocked 상태 유지 |
| queue overflow | 오래된 datagram drop, flow 유지, metric 증가 |
| oversized datagram | 해당 datagram drop, 반복 3회 시 flow 종료 |
| malformed frame | connection 종료, protocol violation metric 증가 |
| remote ICMP unreachable | B2에서는 flow error로 기록하고 후속 datagram drop; ICMP synthesis는 B3 |
| app sleep/wake | health 재검증 후 신규 UDP flow 허용 |

## 10. 관측성과 개인정보

추가 metric:

```text
active_udp_flows
udp_datagrams_mac_to_android
udp_datagrams_android_to_mac
udp_bytes_mac_to_android
udp_bytes_android_to_mac
udp_queue_drops
udp_sequence_gaps
udp_oversized_drops
udp_fragment_drops
udp_idle_timeouts
quic_probe_success
```

목적지 IP, port, DNS name, datagram payload는 장기 로그에 기록하지 않는다. debug build에서도 payload dump 기능을 만들지 않는다.

## 11. 성능 목표

통제된 동일 환경의 Android 직접 baseline과 비교한다.

- UDP throughput: 15 Mbps 이상
- QUIC HTTP/3 10 MiB download 성공
- USB transport 추가 p95 one-way jitter: 25 ms 이하
- DroidBridge 내부 queue drop: 0.5% 이하
- 100개 동시 UDP flow 10분 유지
- 메모리 증가: 10분 안정 구간에서 20 MiB 이하

이 수치는 이동통신망 자체의 손실·지연과 분리해 측정한다.

## 12. 테스트 전략

### 12.1 Core

- valid/invalid IPv4 UDP
- zero/non-zero checksum
- odd-length payload checksum
- fragment rejection
- tuple collision
- timeout cleanup
- queue drop-oldest
- response packet synthesis
- 256-flow hard limit
- parser fuzzing

### 12.2 Android

- cellular bind before connect
- Wi-Fi default network에서도 cellular socket 사용
- datagram boundaries
- timeout/cancellation cleanup
- `onLost` race
- queue overflow
- malformed frame rejection

### 12.3 macOS

- flow manager lifecycle
- relay frame sequence
- backpressure
- DNS exclusion
- USB fault transition
- provider message metrics

### 12.4 실기기

- UDP echo
- QUIC/HTTP3
- WebRTC/voice synthetic UDP
- 100 concurrent flows
- USB detach/reconnect
- cellular loss
- B1 TCP/DNS regression

## 13. B2 수용 기준

1. B1 수용 기준이 모두 재통과한다.
2. Mac 앱별 프록시 설정 없이 IPv4 UDP echo가 동작한다.
3. controlled HTTP/3 endpoint에 QUIC로 연결된다.
4. Android Wi-Fi가 켜져 있어도 UDP socket은 cellular `Network`를 사용한다.
5. 1,232-byte payload를 손실 없이 전달한다.
6. 1,233-byte payload를 명시적으로 drop한다.
7. 100개 동시 UDP flow를 10분 유지한다.
8. USB 분리 시 3초 이내 blocked 상태가 되고 다른 인터페이스로 누출되지 않는다.
9. cellular loss 시 default network로 fallback하지 않는다.
10. private/link-local/multicast destination은 차단된다.
11. malformed DBP datagram frame이 서비스 crash로 이어지지 않는다.
12. UDP throughput 15 Mbps 이상을 기록한다.
13. 2시간 mixed TCP/UDP soak 동안 unbounded memory growth가 없다.
14. payload가 로그·evidence artifact에 포함되지 않는다.

## 14. 구현 순서

1. DBP/1.1 UDP protocol과 fixture
2. C IPv4 UDP parser/checksum/flow engine
3. Android cellular UDP relay
4. Swift relay datagram connection
5. Packet Tunnel UDP integration
6. fault/security/performance acceptance

## 15. 고정 결정

- B2는 one relay TCP connection per UDP flow다.
- B2 payload maximum은 1,232 bytes다.
- IPv4 fragmentation은 지원하지 않는다.
- DNS bridge는 B1 구현을 유지한다.
- queue overflow는 drop-oldest다.
- UDP network migration은 B3다.
- packet payload logging은 구현하지 않는다.
- carrier restriction evasion 기능은 구현하지 않는다.
