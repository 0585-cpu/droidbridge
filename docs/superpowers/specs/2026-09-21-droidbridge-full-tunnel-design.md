# DroidBridge Full-Tunnel 설계 명세

- 문서 상태: 설계 승인 후 작성된 구현 전 명세
- 작성일: 2026-09-21
- 대상 릴리스: B1 MVP
- 프로젝트명: DroidBridge

## 1. 목적

DroidBridge는 사용자가 소유한 Android 단말의 LTE/5G 연결을 USB로 연결된 Mac의 기본 인터넷 출구로 사용하는 로컬 역방향 테더링 도구다. macOS에서는 Network Extension 기반 Packet Tunnel을 구성하고, Android에서는 수신한 연결을 명시적으로 셀룰러 `Network`에 바인딩해 외부 인터넷으로 중계한다.

이 프로젝트의 성공 기준은 다음과 같다.

1. Mac의 일반 TCP 애플리케이션 트래픽이 별도 앱별 프록시 설정 없이 Android의 이동통신 회선으로 나간다.
2. Android와 Mac은 USB 및 ADB 포트 포워딩으로 연결된다.
3. Android 루팅이 필요하지 않다.
4. Mac의 Wi-Fi와 Ethernet이 없는 상태에서도 USB 연결과 Android 모바일 데이터만으로 HTTPS, SSH, Git over HTTPS가 동작한다.
5. 외부에서 관찰되는 출구 주소가 Android 셀룰러 회선의 통신사 주소 대역으로 나타난다.
6. 연결 종료, USB 분리, 셀룰러 손실 시 트래픽이 다른 인터페이스로 조용히 우회되지 않는다.

## 2. 범위와 비범위

### 2.1 B1 MVP 범위

- Apple Silicon Mac
- macOS 14 이상
- Android 8.0/API 26 이상
- Android 16/API 36 compile/target SDK
- IPv4
- TCP 전체 터널
- DNS A/AAAA 및 일반 질의 전달
- USB ADB 전송
- 메뉴바 macOS 호스트 앱
- `NEPacketTunnelProvider` 확장
- Android Foreground Service 릴레이
- 연결 상태, 전송량, 오류 상태 표시
- USB 분리 및 셀룰러 변경 복구
- 로컬 네트워크 기본 차단

### 2.2 후속 범위

- B2: UDP, QUIC/HTTP3, 일반 UDP DNS, 영상통화 및 게임 트래픽
- B3: IPv6, ICMP, 선택적 LAN 예외, 자동 재연결 고도화
- B4: Wi-Fi Direct 또는 USB accessory 기반 ADB 비의존 전송

### 2.3 명시적 비범위

- TTL/Hop Limit 조작
- APN 또는 DUN 설정 변조
- 통신사 테더링 식별값 은닉
- 통신사 과금, 쿼터, 속도 제한의 회피 보장
- 타인 소유 단말 또는 네트워크 사용
- Android 루팅
- macOS 커널 확장
- App Store 또는 Google Play 공개 배포
- 패킷 내용의 장기 저장이나 TLS 복호화

## 3. 설계 원칙

1. **기본 거부:** 셀룰러 릴레이가 준비되지 않으면 Mac 터널은 인터넷 트래픽을 폐기한다.
2. **명시적 셀룰러 바인딩:** Android의 기본 네트워크에 의존하지 않고 각 외부 소켓을 선택된 셀룰러 `Network`에 바인딩한다.
3. **루프 방지:** ADB 포워드가 사용하는 `127.0.0.0/8`은 Packet Tunnel 경로에서 제외한다.
4. **최소 권한:** Android 서버는 단말의 loopback에만 바인딩하고, Mac 호스트 앱은 필요한 Network Extension 및 App Group 권한만 사용한다.
5. **재현 가능한 빌드:** XcodeGen, Gradle Wrapper, 고정된 종속성 체크섬을 사용한다.
6. **허용적 라이선스:** GPL 계열 tun2socks 구현을 직접 포함하지 않고 BSD/MIT/Apache-2.0 호환 코드만 채택한다.
7. **테스트 우선:** 패킷 파서, 프로토콜, DNS, 목적지 정책은 실제 단말 통합 전에 단위 테스트로 검증한다.

## 4. 상위 아키텍처

```text
┌──────────────────────────── macOS ────────────────────────────┐
│                                                              │
│  Safari / Chrome / SSH / Git / 기타 TCP 앱                   │
│                    │                                         │
│                    ▼                                         │
│         NEPacketTunnelProvider                               │
│           198.18.0.2/30                                      │
│                    │ raw IPv4 packets                        │
│                    ▼                                         │
│       DroidBridge Packet Core (C + lwIP)                     │
│         ├─ TCP flow termination                              │
│         ├─ virtual DNS interception                          │
│         └─ destination policy                                │
│                    │ per-flow DBP/1 connection               │
│                    ▼                                         │
│        127.0.0.1:27183 (ADB host listener)                   │
└────────────────────┬─────────────────────────────────────────┘
                     │ USB / adb forward
                     ▼
┌─────────────────────────── Android ───────────────────────────┐
│        127.0.0.1:27183 Android Relay                         │
│                    │                                         │
│          HMAC-authenticated DBP/1                            │
│                    │                                         │
│       CellularNetworkController                              │
│        ├─ request TRANSPORT_CELLULAR                         │
│        ├─ cellular DNS servers                               │
│        └─ network-bound Socket/DatagramSocket                │
│                    │                                         │
│                    ▼                                         │
│                 LTE / 5G                                     │
└────────────────────┬─────────────────────────────────────────┘
                     ▼
                  Internet
```

## 5. 저장소 구조

```text
droidbridge/
├── README.md
├── LICENSE
├── Makefile
├── project.yml                     # XcodeGen
├── macos/
│   ├── HostApp/
│   │   ├── App/
│   │   ├── Device/
│   │   ├── ADB/
│   │   ├── Tunnel/
│   │   ├── Keychain/
│   │   └── UI/
│   ├── PacketTunnel/
│   │   ├── PacketTunnelProvider.swift
│   │   ├── TunnelSettings.swift
│   │   ├── RelayConnector.swift
│   │   └── MetricsPublisher.swift
│   ├── Shared/
│   └── Tests/
├── core/
│   ├── include/droidbridge_core.h
│   ├── src/
│   │   ├── packet_engine.c
│   │   ├── tcp_bridge.c
│   │   ├── dns_bridge.c
│   │   ├── destination_policy.c
│   │   └── dbp_codec.c
│   ├── third_party/lwip/
│   └── tests/
├── android/
│   ├── app/
│   │   └── src/
│   │       ├── main/java/io/droidbridge/
│   │       │   ├── MainActivity.kt
│   │       │   ├── relay/RelayForegroundService.kt
│   │       │   ├── relay/RelayServer.kt
│   │       │   ├── relay/RelaySession.kt
│   │       │   ├── network/CellularNetworkController.kt
│   │       │   ├── network/CellularDnsForwarder.kt
│   │       │   ├── security/PairingSecretStore.kt
│   │       │   └── policy/DestinationPolicy.kt
│   │       └── test/
│   ├── build.gradle.kts
│   ├── settings.gradle.kts
│   └── gradlew
├── protocol/
│   └── dbp-v1.md
├── scripts/
│   ├── bootstrap-macos.sh
│   ├── install-android-debug.sh
│   ├── connect-debug.sh
│   └── disconnect-debug.sh
└── docs/
    ├── threat-model.md
    ├── operations.md
    └── superpowers/specs/
```

## 6. macOS 설계

### 6.1 HostApp

SwiftUI 메뉴바 애플리케이션이며 다음 책임만 가진다.

- `adb` 실행 파일 탐색
- 연결된 Android 기기 열거
- 한 대의 승인된 기기 선택
- Android 릴레이 앱 설치 상태와 버전 확인
- `adb forward tcp:27183 tcp:27183` 생성 및 제거
- 릴레이 앱 시작 화면 호출
- `NETunnelProviderManager` 구성 저장과 터널 시작/중지
- Pairing Secret을 macOS Keychain에 저장
- 상태와 송수신량 표시
- USB 분리 시 Packet Tunnel을 차단 상태로 전환하고 재연결을 시도하며, 사용자의 명시적 Disconnect 전에는 터널 설정을 제거하지 않음

HostApp은 패킷을 처리하지 않는다. 패킷 데이터는 PacketTunnel 확장과 core 라이브러리에서만 처리한다.

### 6.2 PacketTunnel 확장

`NEPacketTunnelProvider`를 사용한다.

터널 설정:

```text
Virtual address: 198.18.0.2
Subnet:          255.255.255.252
Virtual DNS:     198.18.0.1
Included route:  0.0.0.0/0
Excluded route:  127.0.0.0/8
MTU:             1280 bytes
```

MTU 1280은 초기 구현에서 캡슐화와 단편화 문제를 줄이기 위한 보수적 값이다. B2 성능 시험 후 상향 조정할 수 있으나 B1 완료 기준에는 1280을 유지한다.

확장의 실행 순서:

1. App Group에서 대상 기기 ID, host relay port, Pairing Secret reference를 읽는다.
2. `127.0.0.1:27183`의 relay health check를 수행한다.
3. `NEPacketTunnelNetworkSettings`를 적용한다.
4. packetFlow에서 패킷 읽기 루프를 시작한다.
5. IPv4 패킷을 Packet Core에 투입한다.
6. core가 생성한 반환 패킷을 packetFlow에 기록한다.
7. relay 또는 cellular 상태가 사라지면 모든 흐름을 종료하고 kill-switch 상태를 유지한다.

### 6.3 Packet Core

C ABI를 제공하는 정적 라이브러리다. Swift 확장과 분리하여 단위 테스트와 향후 다른 호스트 지원을 가능하게 한다.

역할:

- IPv4 패킷 검증
- TCP checksum과 상태 처리
- lwIP 기반 TCP 종단
- 목적지별 outbound bridge 생성
- Android Relay 연결 관리
- DNS 가상 서버 처리
- idle flow 정리
- 전송량 계측

핵심 C ABI:

```c
typedef struct db_engine db_engine_t;

typedef void (*db_emit_packet_fn)(
    const uint8_t *packet,
    size_t length,
    void *context
);

typedef int (*db_open_flow_fn)(
    uint64_t flow_id,
    const db_destination_t *destination,
    void *context
);

typedef int (*db_send_flow_fn)(
    uint64_t flow_id,
    const uint8_t *data,
    size_t length,
    void *context
);

typedef void (*db_close_flow_fn)(
    uint64_t flow_id,
    int reason,
    void *context
);

db_engine_t *db_engine_create(const db_engine_config_t *config);
void db_engine_ingest_ipv4(db_engine_t *engine,
                           const uint8_t *packet,
                           size_t length);
void db_engine_on_relay_opened(db_engine_t *engine,
                               uint64_t flow_id);
void db_engine_on_relay_open_failed(db_engine_t *engine,
                                    uint64_t flow_id,
                                    int error_code);
void db_engine_on_relay_data(db_engine_t *engine,
                             uint64_t flow_id,
                             const uint8_t *data,
                             size_t length);
void db_engine_on_relay_closed(db_engine_t *engine,
                               uint64_t flow_id,
                               int error_code);
void db_engine_tick(db_engine_t *engine, uint64_t monotonic_ms);
void db_engine_destroy(db_engine_t *engine);
```

### 6.4 Relay 연결 모델

B1은 TCP flow 하나당 ADB-forwarded TCP 연결 하나를 사용한다.

장점:

- 흐름 간 head-of-line blocking 방지
- 단순한 장애 격리
- 별도 multiplexing 구현 불필요
- Android coroutine 한 개로 세션 처리 가능

제한:

- 많은 짧은 연결에서 handshake 비용 증가
- ADB 연결 수 증가

B1 제한은 동시 활성 흐름 256개, 기본 최대 128개다. 초과 흐름은 TCP RST로 종료한다.

## 7. Android 설계

### 7.1 UI

Jetpack Compose 단일 화면으로 구성한다.

표시 항목:

- 릴레이 실행 상태
- 모바일 데이터 네트워크 상태
- 통신사 표시명
- 연결된 Mac의 식별자
- 활성 TCP 흐름 수
- 업로드/다운로드 바이트
- 마지막 오류
- Pairing Secret 재생성 버튼
- 릴레이 시작/중지 버튼

### 7.2 Foreground Service

사용자가 Android 화면에서 명시적으로 시작한다. 서비스가 시작되면 지속 알림을 표시한다. Android 14 이상 요구사항에 맞춰 foreground service type은 `connectedDevice`로 선언한다. 이 유형은 USB 또는 네트워크로 연결된 외부 기기와 지속적으로 상호작용하는 용도에 맞으며, manifest에는 `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`, `CHANGE_NETWORK_STATE`, `ACCESS_NETWORK_STATE`, `INTERNET`를 선언한다. Android 13 이상에서는 알림 표시를 위해 `POST_NOTIFICATIONS`를 요청한다.

서비스는 백그라운드나 부팅 수신기에서 자동 시작하지 않는다. 사용자가 화면에서 Start를 누른 직후 foreground service를 시작한다.

책임:

- 셀룰러 Network 요청
- loopback relay server 시작
- 세션 인증
- 외부 TCP 소켓 생성과 셀룰러 바인딩
- DNS 질의 전달
- 연결 수와 전송량 집계
- 화면 꺼짐 상태에서도 세션 유지
- 서비스 종료 시 callback 해제와 소켓 정리

배포 대상은 개발자용 sideload이므로 공개 스토어 배포를 전제로 한 백그라운드 정책 우회는 하지 않는다. 서비스는 사용자가 시작하고 지속 알림을 통해 실행 상태를 명확히 노출한다.

### 7.3 CellularNetworkController

다음 조건의 `NetworkRequest`를 사용한다.

```text
TRANSPORT_CELLULAR
NET_CAPABILITY_INTERNET
```

`onAvailable`에서 선택된 `Network`를 보관하고, 모든 외부 TCP 소켓은 해당 `Network.getSocketFactory()`로 생성한다. UDP/DNS 소켓은 연결 전에 `Network.bindSocket()`으로 바인딩한다.

네트워크 손실 시:

1. 신규 흐름 수락 중단
2. 기존 흐름 종료
3. Mac health channel에 `CELLULAR_LOST` 전달
4. 새 셀룰러 Network 요청
5. 회복 후 신규 흐름 수락

Wi-Fi가 활성화되어 있어도 외부 relay socket은 셀룰러 Network를 사용한다.

### 7.4 RelayServer

- Bind address: `127.0.0.1`
- Port: `27183`
- Max sessions: 128 기본, 256 hard limit
- Connect timeout: 10초
- Idle timeout: 5분
- Initial authentication timeout: 3초
- TCP buffer: 방향별 64 KiB

각 세션은 Kotlin coroutine으로 처리하며, blocking I/O는 `Dispatchers.IO`에서 수행한다. 한 방향이 EOF이면 반대 방향에 half-close를 적용하고 10초 후 완전 종료한다.

## 8. DBP/1 프로토콜

DBP는 DroidBridge Protocol의 약자다. B1에서는 TCP와 DNS 요청만 지원한다.

### 8.1 최초 페어링

Pairing Secret을 명령행 인자나 평문 파일로 전달하지 않는다. 최초 1회 다음 절차를 사용한다.

1. 사용자가 Android 앱에서 **Pair New Mac**을 눌러 60초간 loopback pairing endpoint를 연다.
2. HostApp이 ADB port forward를 구성하고 pairing endpoint에 연결한다.
3. 양쪽이 ephemeral P-256 ECDH key pair와 256-bit nonce를 생성하고 public key와 nonce를 교환한다.
4. ECDH shared secret과 전체 handshake transcript를 HKDF-SHA256에 넣어 256-bit Pairing Secret을 만든다.
5. transcript hash에서 6자리 Short Authentication String을 계산해 Mac과 Android 양쪽에 표시한다.
6. 사용자가 두 코드가 같은지 확인하고 양쪽에서 승인한다. 한쪽이라도 거부하거나 60초가 지나면 secret을 폐기한다.
7. 승인 후 Mac은 Keychain에, Android는 Keystore로 보호된 저장소에 Pairing Secret과 상대 기기 식별자를 저장한다.

동일 Mac의 이후 연결은 저장된 Pairing Secret으로 HMAC challenge-response를 수행한다. Android 앱에서 기기 등록을 삭제하거나 Pairing Secret을 재생성하면 기존 Mac 등록은 즉시 무효화된다.

### 8.2 공통 헤더

```text
Offset  Size  Field
0       4     Magic = "DBP1"
4       1     Message type
5       1     Flags
6       2     Header length, network byte order
8       8     Client nonce
16      8     Server nonce or zero in request
24      8     Unix time seconds
32      32    HMAC-SHA256
64      N     Type-specific payload
```

HMAC 입력은 HMAC 필드를 0으로 둔 전체 헤더와 payload다. Pairing Secret은 256-bit random value이며 Android Keystore 보호 저장소와 macOS Keychain에 저장한다.

허용 시간 편차는 120초다. 최근 1024개 nonce를 5분간 보관해 replay를 거부한다. 비교는 constant-time으로 수행한다.

### 8.3 메시지 종류

```text
0x01 HELLO
0x02 HELLO_OK
0x10 OPEN_TCP
0x11 OPEN_OK
0x12 OPEN_ERROR
0x20 DNS_QUERY
0x21 DNS_RESPONSE
0x30 HEALTH
0x31 HEALTH_RESPONSE
```

### 8.4 OPEN_TCP payload

```text
1 byte   address type: 1=IPv4, 3=domain
2 bytes  destination port
1 byte   address/domain length
N bytes  address/domain
```

Android는 인증과 목적지 정책 검사를 통과한 뒤 셀룰러 Network socket을 생성한다. 성공 시 `OPEN_OK`를 반환하고 이후 연결은 raw byte stream으로 전환된다.

### 8.5 오류 코드

```text
1 AUTH_FAILED
2 VERSION_UNSUPPORTED
3 POLICY_DENIED
4 CELLULAR_UNAVAILABLE
5 DNS_FAILED
6 CONNECT_TIMEOUT
7 CONNECT_REFUSED
8 SESSION_LIMIT
9 INTERNAL_ERROR
```

## 9. DNS 설계

macOS는 DNS server로 `198.18.0.1`을 사용한다. Packet Core는 이 주소의 UDP/TCP 53 패킷을 외부 TCP flow로 만들지 않고 DNS bridge가 처리한다.

Android DNS 처리:

1. 선택된 셀룰러 `Network`의 `LinkProperties.dnsServers`를 읽는다.
2. 원본 DNS query를 첫 번째 DNS server에 network-bound UDP socket으로 전송한다.
3. 2초 내 응답이 없으면 다음 DNS server로 시도한다.
4. 응답의 TC bit가 설정되면 같은 서버에 TCP DNS로 재시도한다.
5. 전체 제한 시간은 5초다.
6. 원본 transaction ID를 유지해 Mac에 반환한다.

DNS cache는 B1에서 구현하지 않는다. macOS와 애플리케이션 계층 캐시를 사용하고, 개인정보 최소화를 위해 질의 이름을 장기 저장하지 않는다.

## 10. 목적지 정책

기본 차단 대상:

```text
0.0.0.0/8
10.0.0.0/8
100.64.0.0/10
127.0.0.0/8
169.254.0.0/16
172.16.0.0/12
192.0.0.0/24
192.0.2.0/24
192.168.0.0/16
198.18.0.0/15
198.51.100.0/24
203.0.113.0/24
224.0.0.0/4
240.0.0.0/4
```

이 정책은 Android 단말의 내부망, loopback, link-local, multicast 및 문서/벤치마크 대역으로 프록시 피벗되는 것을 방지한다. 사용자가 명시적으로 LAN access를 활성화하는 기능은 B3에서 별도 위험 경고와 함께 구현한다.

도메인 입력은 Android 셀룰러 DNS로 해석한 뒤 반환된 모든 IP에 정책을 다시 적용한다. DNS rebinding을 막기 위해 연결에 실제 사용되는 최종 IP도 검사한다.

## 11. Kill Switch와 라우팅

B1은 fail-closed다.

- Packet Tunnel이 활성화된 동안 `0.0.0.0/0`은 터널에 포함된다.
- relay health check 실패 시 터널 설정을 제거하지 않고 패킷을 폐기한다.
- HostApp이 명시적으로 Disconnect를 수행할 때만 기본 macOS 라우팅이 복원된다.
- Android 셀룰러 손실 시 Wi-Fi relay로 자동 대체하지 않는다.
- USB 분리 감지 후 3초 내 차단 상태로 전환한다. Packet Tunnel은 유지하며 모든 인터넷 패킷을 폐기하고, 사용자가 명시적으로 Disconnect할 때만 기본 macOS 라우팅을 복원한다.

`127.0.0.0/8`만 제외하여 PacketTunnel 확장에서 ADB host listener에 접근한다. B1에서는 로컬 LAN 예외를 제공하지 않는다.

이 fail-closed 보장은 Packet Tunnel provider가 정상 실행 중인 장애 시나리오를 대상으로 한다. macOS 재부팅, Network Extension 강제 종료 또는 운영체제 수준의 VPN 구성 제거까지 포함하는 강제 상시 VPN은 일반 로컬 앱만으로 보장하지 않으며, 그 수준은 관리형 Always-On VPN/MDM 범위다.

## 12. 오류 처리와 복구

| 사건 | 동작 |
|---|---|
| Android 앱 미실행 | HostApp이 연결을 시작하지 않고 실행 안내 표시 |
| ADB unauthorized | Android의 USB 디버깅 승인 안내 |
| 여러 Android 기기 | 사용자가 한 기기를 명시적으로 선택 |
| relay 인증 실패 | 터널 시작 중단, Pairing Secret 재등록 안내 |
| cellular unavailable | fail-closed, Android와 Mac에 상태 표시 |
| 목적지 연결 실패 | 해당 TCP flow에 RST/오류 반환 |
| USB 분리 | 모든 흐름 정리, 터널 유지 및 차단 상태 전환, 제한된 재연결 시도 |
| Android 프로세스 종료 | health 실패 후 fail-closed 유지 |
| Mac sleep | wake 후 ADB/relay 재검증, 실패 시 터널 유지 및 차단 상태 전환 |
| network 변경 | 기존 flow 종료, 새 cellular Network에서 신규 flow만 수락 |

자동 재연결은 최대 3회, 간격 1초·2초·4초로 제한한다. 이후 사용자가 다시 Connect를 눌러야 한다.

## 13. 관측성과 개인정보

기본 로그:

- 상태 전환 시각
- 익명화된 flow ID
- 목적지 포트
- 전송 바이트 수
- 종료 사유와 오류 코드
- RTT와 연결 설정 시간

기본적으로 기록하지 않는 정보:

- 패킷 payload
- HTTP URL
- TLS SNI
- 쿠키와 인증 헤더
- DNS query name의 영구 로그
- 사용자 계정 정보

디버그 빌드에서도 payload dump 기능은 제공하지 않는다. OSLog의 privacy redaction을 사용한다.

## 14. 성능 목표

B1 실기기 기준 목표:

- 활성 TCP flow 128개
- 50 Mbps 이상 단방향 처리량
- 추가 RTT 중앙값 15 ms 이하, USB 로컬 구간 기준
- 1시간 연속 HTTPS 다운로드에서 비정상 종료 없음
- relay idle 상태 Android 추가 배터리 사용 최소화
- 메모리: Mac extension 150 MiB 이하, Android service 120 MiB 이하

성능 목표는 기능 수용 기준과 분리한다. 20 Mbps 미만 또는 추가 RTT 40 ms 초과이면 B1 릴리스를 차단한다.

## 15. 테스트 전략

### 15.1 Core 단위 테스트

- 잘린 IPv4/TCP 헤더 거부
- 잘못된 checksum 처리
- TCP SYN/ACK/FIN/RST 상태 전이
- flow timeout
- destination CIDR 정책
- DNS packet validation
- DBP header encoding/decoding
- HMAC 검증과 replay 거부
- fuzz test: IPv4, TCP, DNS, DBP parser

### 15.2 Android 단위 테스트

- Cellular Network 선택 로직
- Network loss callback
- 목적지 정책
- HMAC 인증
- DNS UDP→TCP fallback
- socket timeout과 half-close
- session limit

### 15.3 macOS 단위 테스트

- tunnel settings 생성
- App Group configuration
- ADB output parsing
- device selection
- Keychain read/write
- state machine

### 15.4 통합 테스트

1. Android Wi-Fi OFF, 모바일 데이터 ON
2. Mac Wi-Fi OFF, Ethernet 미연결
3. USB 연결과 ADB 승인
4. DroidBridge Connect
5. `curl https://example.com`
6. Git HTTPS clone
7. SSH TCP 연결
8. 1 GiB 파일 다운로드
9. USB 분리 후 트래픽 차단 확인
10. 재연결 후 새 세션 복구 확인
11. Android Wi-Fi ON 상태에서도 셀룰러 출구 확인
12. 사설 IP 연결 차단 확인

### 15.5 출구 검증

Android 자체 모바일 데이터와 Mac 터널 상태에서 각각 IP/ASN 정보를 조회한다. 두 결과는 동일한 통신사 ASN 또는 이동통신사 주소 대역이어야 한다. 주소가 정확히 동일할 필요는 없으며 CGNAT 정책에 따라 달라질 수 있다.

## 16. B1 수용 기준

다음 조건을 모두 충족해야 B1을 완료로 처리한다.

1. 실제 Apple Silicon Mac과 실제 Android 단말에서 빌드·설치된다.
2. Android 루팅 없이 작동한다.
3. Mac 애플리케이션별 프록시 설정 없이 TCP 트래픽이 전달된다.
4. DNS 이름 기반 HTTPS 접속이 된다.
5. Android Wi-Fi가 켜져 있어도 relay outbound socket이 셀룰러로 나간다.
6. Mac Wi-Fi와 Ethernet을 끈 상태에서 HTTPS, SSH, Git HTTPS가 동작한다.
7. Packet Tunnel provider가 실행 중인 상태에서 USB 분리 또는 셀룰러 손실 시 차단 상태를 유지하며 다른 인터페이스로 누출되지 않는다.
8. 목적지 사설망 차단 정책이 적용된다.
9. 인증되지 않은 relay 요청이 거부된다.
10. 128개 동시 TCP flow 테스트를 통과한다.
11. 1시간 안정성 테스트를 통과한다.
12. 20 Mbps 이상, 추가 RTT 40 ms 이하를 만족한다.
13. 패킷 payload를 로그나 파일에 저장하지 않는다.
14. TTL, APN, DUN 또는 통신사 설정을 변경하지 않는다.

## 17. 단계별 구현 순서

### B1.0 빌드 골격

- 저장소와 CI
- XcodeGen 프로젝트
- macOS HostApp + PacketTunnel targets
- Android Gradle 프로젝트
- C core library와 테스트 harness

### B1.1 Android TCP relay

- CellularNetworkController
- loopback RelayServer
- DBP/1 인증
- network-bound outbound TCP
- Android UI와 foreground service

### B1.2 macOS ADB orchestration

- adb 탐색/기기 선택
- 앱 실행과 포트 forward
- health check
- Keychain/App Group

### B1.3 Packet Tunnel 및 TCP core

- Network Extension 설정
- packet read/write loop
- lwIP integration
- per-flow relay connector
- kill switch

### B1.4 DNS

- virtual DNS interception
- Android cellular DNS forwarder
- truncation TCP retry

### B1.5 보안과 복구

- destination policy
- replay protection
- USB/cellular loss state machine
- log redaction

### B1.6 검증

- unit/fuzz/integration tests
- throughput/latency test
- 1시간 soak test
- threat-model review

## 18. 주요 리스크와 대응

### 18.1 Apple Network Extension 권한

Network Extensions capability와 Packet Tunnel Provider entitlement가 필요하다. 로컬 개발 및 서명된 배포를 위해 Apple Developer Program 팀 설정을 사용한다. 권한이 없는 환경에서는 HostApp UI만 빌드되고 터널은 실행되지 않는다.

### 18.2 사용자 공간 TCP 구현 복잡도

직접 TCP를 새로 구현하지 않고 lwIP를 vendoring한다. glue layer는 패킷 투입, timer, outbound flow, 반환 패킷에만 집중한다. parser와 state transition에 fuzz test를 적용한다.

### 18.3 ADB 의존성

B1은 개발자 옵션과 USB debugging이 필요하다. HostApp은 ADB 미설치, unauthorized, offline 상태를 구분해서 표시한다. ADB 비의존 USB 전송은 B4로 분리한다.

### 18.4 단일 흐름당 TCP-over-TCP 영향

Mac의 TCP flow를 ADB의 TCP 연결로 전달하므로 손실 환경에서 TCP-over-TCP 지연이 발생할 수 있다. USB 구간은 짧고 안정적이라는 전제로 B1을 구현한다. B2 이후 필요하면 ADB local socket 또는 프레임 기반 다중 채널을 평가한다.

### 18.5 Android OEM 백그라운드 종료

Foreground Service와 지속 알림을 사용하고, 배터리 최적화 상태를 UI에 표시한다. OEM별 강제 종료는 완전히 통제할 수 없으므로 health failure 시 fail-closed한다.

## 19. 구현 시 고정 결정

- macOS UI: SwiftUI
- macOS 터널: `NEPacketTunnelProvider`
- packet core: C + lwIP
- Android: Kotlin + Jetpack Compose + Coroutines
- transport: USB ADB TCP forward
- protocol: DBP/1 + HMAC-SHA256
- secret storage: macOS Keychain / Android Keystore-backed storage
- B1 IP family: IPv4 only
- B1 application traffic: TCP
- DNS: tunnel 내 가상 DNS + Android cellular DNS relay
- failure mode: fail-closed
- default LAN policy: deny
- distribution: local developer-signed/sideload only

## 20. 공식 참고 자료

- Apple Network Extension framework: https://developer.apple.com/documentation/networkextension
- Apple `NEPacketTunnelProvider`: https://developer.apple.com/documentation/networkextension/nepackettunnelprovider
- Apple macOS supported capabilities: https://developer.apple.com/help/account/reference/supported-capabilities-macos/
- Android `ConnectivityManager`: https://developer.android.com/reference/android/net/ConnectivityManager
- Android `Network`: https://developer.android.com/reference/android/net/Network
- Android Debug Bridge port forwarding: https://developer.android.com/tools/adb#set-up-port-forwarding
- lwIP project: https://www.nongnu.org/lwip/

## 21. 설계 완료 판정

이 명세는 구현에 필요한 목적, 범위, 구성요소, 인터페이스, 보안 경계, 오류 동작, 시험과 완료 조건을 고정한다. 구현 단계에서 기능 범위를 넓히지 않으며, B1 수용 기준에 직접 필요한 변경만 허용한다. UDP, IPv6, ADB 비의존 USB 전송은 각각 별도 설계 명세를 작성한 뒤 착수한다.
