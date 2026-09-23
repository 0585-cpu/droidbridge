# DroidBridge UDP·QUIC 및 트래픽 프로필 설계 보충

> 전송 계층은 [AOA 설계](../specs/2026-09-23-droidbridge-aoa-design.md)로 갱신됐다. UDP·QUIC·TTL 범위는 유지하며 AOA 실기기 검증 이후 진행한다.
- 작성일: 2026-09-23
- 상태: 개발 계획용 설계. 신규 기능은 아직 구현·실기기 검증되지 않았다.
- 기준 구현: `9d94ede`, signed root utun helper + configd + pf + USB ADB + Android cellular relay.
- 사용자 요구: 일반 UDP·QUIC와 TTL 변경·트래픽 위장 기능을 모두 포함한다.
- 유지하는 전제: macOS 14+/Apple Silicon, Android API 26+, Android root 불필요, 휴대폰 Wi-Fi 연결과 무관하게 LTE/5G 사용.

## 기존 명세와의 관계

이 문서는 기존 B1/B2/B3 명세의 **향후 TTL/Hop Limit 및 트래픽 조절 제외 조건**을 변경한다. B1 기본 프로필의 과거 수용시험 기준은 변경하지 않는다. APN/DUN·통신사 설정 변경, TLS 중간자 복호화, Android root는 추가하지 않는다.

기존 문서의 NEPacketTunnelProvider 중심 통합은 현재의 `UtunPacketSource → CoreHost → Android relay`로 대체한다. 유료 NetworkExtension entitlement를 출시 선행 조건으로 삼지 않는다. signed helper 설치·XPC 권한·복구 저널 검증은 유지한다.

## 구조와 우선순위

```text
Mac 앱 → utun → C TCP/UDP 엔진 → 인증된 DBP 세션 → USB/AOA
       → Android TCP/UDP 소켓 → 선택된 cellular Network → 인터넷
```

1. B1 결함 수정 및 실기기 수용시험.
2. B2 일반 IPv4 UDP·QUIC/HTTP3.
3. 선택형 TTL·DNS 필터·전송률 및 버스트 조절.
4. B3 IPv6/Hop Limit·ICMP capability·복구 확장.

현재 릴레이를 확장한다. RNDIS/TetherKit 전환이나 Linux 방화벽 스크립트 이식은 의존성이 아니다. TTL 기능 때문에 일반 UDP를 뒤로 미루지 않는다.

## 일반 UDP·QUIC 계약

- 인증된 UDP flow당 relay TCP 연결 하나. AOA bulk 전송을 공유하므로 flow 사이의 USB 정체 영향까지 성능 시험에 반영한다.
- datagram 경계 및 길이 0 보존. payload 최대 1,232 bytes, IPv4 fragment 재조립 없음.
- UDP flow 기본 128/최대 256, TCP+UDP 최대 512.
- 방향별 queue는 64 datagrams 또는 256 KiB 중 먼저 도달한 제한, overflow는 drop-oldest.
- idle 기본 120초, 협상 범위 30–300초, cleanup 주기 5초.
- cellular bind 후 connect. Network generation 변경이나 bind 실패 시 close하며 다른 회선 fallback은 없다.
- OPEN_UDP 전 capability 확인. 구형 peer와 TCP/DNS 연결은 유지한다.
- 현재 UDP/53 DNS interception을 보존하고 일반 UDP보다 먼저 처리한다. 기존 명세의 virtual DNS 전용 설명보다 이 호환 조건이 우선한다.
- malformed frame은 연결 종료, 목적지 정책은 TCP와 동일하게 적용한다.

앱의 암호화된 QUIC datagram을 중계하며 QUIC 프로토콜을 직접 구현하지 않는다. HTTP/3 전용 클라이언트에서 HTTP 버전 3과 10 MiB 전송 성공을 확인한다. HTTP/2 fallback은 QUIC 성공으로 인정하지 않는다.

## TTL / Hop Limit

Mac IP packet은 셀룰러망으로 그대로 forwarding되지 않는다. Android가 새 외부 소켓을 생성하므로 TTL 변경은 그 소켓에 적용한다. Mac 전역 TTL은 변경하지 않는다.

- 기본값은 운영체제 기본 TTL/Hop Limit 유지. 사용자 지정은 각각 1–255. 숫자 65를 보편적 정답으로 고정하지 않는다.
- 첫 버전은 Android UI에서 설정하고 relay 재시작 시 적용한다. 실행 중 편집을 거부하고 시작 시 불변 설정을 snapshot한다.
- TCP, DNS UDP/TCP, 일반 UDP에 같은 정책을 적용한다.
- 순서: 생성 → cellular bind → 옵션 설정·되읽기 → connect/send.
- 지정값 적용 실패 시 해당 소켓을 닫고 원인을 표시한다. 기본값으로 조용히 대체하지 않는다.
- API 26+ 공개 Os socket API 및 공개 FD 접근 경로만 사용한다. 복제 FD의 close가 원본 소켓을 닫지 않는지 시험한다.
- IPv4-mapped IPv6 소켓 및 IPv6-only/464XLAT 회선도 시험한다. 미지원 조합은 명시한다.
- IPv6 forwarding과 Hop Limit 전체 수용시험은 B3에 둔다. B2에서도 외부 TCP/DNS 소켓의 실제 주소 계열을 구별한다.
- Mac은 인증된 상태 조회로 활성 프로필·적용 오류를 표시한다. B1 health payload를 무조건 늘리지 않고 capability와 별도 버전 응답으로 호환성을 유지한다.

## 트래픽 조절

| 기능 | 구현 범위 | 기본값·한계 |
|---|---|---|
| DNS 경로 | 기존 cellular DNS bridge 및 Mac의 다른 회선 차단 | DoH/DoT도 cellular 경로를 확인하되 휴대폰 DNS로 강제했다고 표시하지 않음 |
| IPv6 경로 | B2 Mac IPv6 외부 누출 차단, B3 relay 전달 | 휴대폰 전체 IPv6 비활성화 없음; IPv6-only cellular/NAT64와 구별 |
| 업데이트 도메인 필터 | DNS bridge의 정확한 이름 또는 label 경계 suffix 차단 | OFF; DoH/DoT·캐시·direct IP에는 보장되지 않는 DNS 필터, 보안 업데이트 영향 표시 |
| 속도·버스트 조절 | Android relay의 aggregate token bucket 및 flow별 bounded queue | OFF; monotonic clock, UDP datagram 원자성 유지, 다운로드는 backpressure이며 이미 수신한 cellular 바이트를 취소하지 못함 |
| MTU/MSS 실험 | USB 구간과 외부 TCP 구간을 구분한 비교 시험 | 기본 MTU 1,280 유지; 성능·재전송·연결 안정성 근거가 있을 때만 변경 |

TLS ClientHello, 암호화된 HTTP User-Agent 또는 앱 동작 전체를 Android 앱처럼 변환하지 않는다. UI에는 개별 옵션의 적용 상태와 측정치를 표시한다.

## 근거와 검증

[pdanet-linux의 wifi-stealth.sh](https://github.com/wtyler2505/pdanet-linux/blob/main/scripts/wifi-stealth.sh)를 2026-09-23에 확인했다. TTL/Hop Limit, IPv6 차단, DNS redirect, 업데이트 문자열 차단이 있다. MSS 규칙은 FORWARD에 있고 해당 스크립트의 shaping 부분은 주석과 출력만 있다. 설명 문구를 검증된 탐지 회피 효과로 인용하지 않는다. 직접 소스를 가져오면 원본 MIT 고지와 출처를 보존한다.

Android 공개 API 근거: [Os](https://developer.android.com/reference/android/system/Os), [OsConstants](https://developer.android.com/reference/android/system/OsConstants).

- B1: 기존 14개 acceptance. USB만 시험한 결과로 전체 장애 대응을 통과 처리하지 않는다.
- B2: 기존 14개 acceptance, 길이 0/1,232/1,233 경계, HTTP/3 강제 시험, helper 회귀.
- 프로필: OFF 상태 B1/B2 회귀, TTL 되읽기·외부 헤더 비교, 적용 실패 폐쇄, 필터 경계, shaping 자원 제한·취소.
- B3: 기존 dual-stack/복구 gate와 IPv6 Hop Limit·IPv6-only cellular 시험.
- 제어 가능한 외부 endpoint와 실제 기기에서 시험한다. 환경이 없으면 해당 항목은 미실행이다.
- 패킷 비교는 생성한 시험 트래픽만 사용하고 필요한 헤더/집계값만 보존한다. 일반 사용자의 payload·DNS name·목적지 이력을 저장하지 않는다.
- 휴대폰 직접 연결과 DroidBridge를 같은 endpoint·가까운 시간대에서 비교한다. 서버 관측 TTL에는 중간 hop이 반영되므로 설정값과 같은 숫자인지만으로 판정하지 않는다.
- 통신사 분류·사용량 집계 변화는 별도 관측한다. 패킷 옵션 변경만으로 분류·과금 변경을 보장하지 않는다.
