# DroidBridge 2·3·4 구현 및 검증 계획

사용자 지시: **일반 UDP·QUIC → TTL·트래픽 프로필 → IPv6·복구의 소프트웨어를 먼저 구현하고, 실기기 검증은 마지막에 수행한다.** 현재 Tetrd를 유지하며 APK 설치, AOA 전환, Helper 교체, 실제 경로 변경은 실행하지 않는다.

기준: AOA 구현 commit `692a964`, 작업 branch `codex/aoa-transport`.
공통 wire/ABI는 [구현 계약](../specs/2026-09-23-droidbridge-implementation-contract.md)이 이전 B2/B3 문서의 모호하거나 충돌하는 내용을 대체한다.

## 2. 일반 UDP·QUIC

- [x] B1 HELLO/HMAC/HEALTH 유지, 별도 인증 CAPABILITIES 협상, 구형 TCP4 호환 및 인증·시간초과 실패 차단.
- [x] C IPv4/IPv6 UDP parser, checksum·fragment·목적지 정책, UDP/53 DNS 우선, 256 UDP/512 combined 한도와 idle 정리.
- [x] Kotlin/Swift OPEN_UDP 및 raw datagram framing. 빈 payload와 최대 1232 bytes를 보존하며 초과·예약 필드를 거부.
- [x] 비동기 OPEN 중 첫 패킷 보관, 최대 64개/256 KiB drop-oldest 송신 큐, 수신 backpressure, 독립된 송수신, EOF 정리.
- [x] Android cellular bind→옵션→connect, generation 변경 시 소켓 정리 및 다른 회선 fallback 차단.
- [x] Mac C ABI 복사·직렬화, UDP count/drop/capability 화면, 재시작 시 이전 엔진 파괴와 응답 격리.
- [x] 공통 canonical fixture를 C/Kotlin/Swift에서 검사.
- [ ] 실기기 UDP/HTTP3, 100 flows, 처리량·지연·2시간 mixed soak: [대기표](../../udp-ipv6-device-acceptance.md).

QUIC 암호화·세션은 앱/서버가 처리하며 DroidBridge는 UDP를 전달한다. 실제 HTTP/3 성공이나 무중단 QUIC 이동을 자동 테스트 결과로 주장하지 않는다.

## 3. TTL·트래픽 프로필

- [x] Android nullable TTL/Hop Limit 1–255, 기본 OS 값 유지, 모든 TCP/DNS/UDP/ICMP 소켓에 적용.
- [x] 공개 Android API로 설정하고 작은 JNI/NDK `getsockopt`로 되읽기. 실패 시 해당 소켓을 닫음.
- [x] DNS suffix 필터 기본 OFF, label 경계·대소문자·압축 오류 검사, NXDOMAIN 응답.
- [x] 방향별 공유 token bucket, 전송률·burst 설정, UDP 원자성 및 취소 가능한 대기.
- [x] 프로필 저장/복원, 잘못된 저장값 기본값 복구, 실행 중 편집 거부, 설정값·통계 표시.
- [x] Android API 26–28 FD 소유권 및 다중 flow I/O 격리 최종 리뷰 회귀 검증. 40 UDP + 20 TCP 동안 HEALTH/control 진행 확인.
- [ ] 실제 Android socket readback, 464XLAT, 외부 TTL/Hop 관측 및 전송률 오차 측정.

DNS 필터는 relay DNS에만 적용한다. DoH/DoT·직접 IP는 필터링하지 않는다. 다운로드 shaping은 휴대폰에 이미 수신된 데이터 과금량의 상한이 아니다. 통신사 분류·과금 변화는 보장하지 않는다.

## 4. IPv6·복구

- [x] IPv6 TCP는 검증된 패킷을 기존 lwIP TCP 상태 머신에 연결하고 원래 IPv6 tuple/checksum으로 응답을 합성.
- [x] IPv6 UDP, 제한된 extension header, fragmentation 차단, 공인 목적지와 NAT64 내 embedded IPv4 정책.
- [x] IPv6 사용 가능 여부·NAT64 prefix 협상, IPv6 불가 시 AAAA 억제와 flow 거부.
- [x] 공개 Android ping datagram socket 기반 ICMP Echo; probe 성공한 주소군만 capability 광고.
- [x] Mac utun AF_INET6, configd IPv4/IPv6 게시·되읽기·철회, dormant NetworkExtension 설정 동기화.
- [x] Stop 시 C 엔진 즉시 파괴, 네트워크 epoch별 DNS/ICMP 취소·지연 응답 차단, 새 flow로 복구.
- [ ] 실기기 IPv4-only/dual-stack/NAT64, ICMP, USB·cellular·sleep 장애, 8시간 mixed soak.

선택형 LAN 우회는 이번 2·3·4 범위 밖이며 기본 fail-closed를 유지한다. Android의 사용자 정의 NAT64 prefix 보고는 공개 API 30+의 /96 범위이며 이전 버전은 표준 prefix 정책을 사용한다.

## 자동 검증과 배포 준비

- [x] C 56 tests, ASan/UBSan, IP/DBP/DNS parser fuzz.
- [x] Python 27 tests 중 22 PASS/5 환경별 SKIP, canonical fixture 재생성 검사.
- [x] Swift Shared 236 checks, Helper/CoreHost 12 checks, operation lock 및 AOA loopback multiplex 검사.
- [x] 서명된 Mac Host/Helper 빌드와 서명 검증, dormant NE unsigned 빌드.
- [x] Android 126 unit tests, lint/debug APK/instrumentation APK, JNI 4 ABI 빌드 및 host native socket readback 검사.
- [x] C/Swift/Android 최종 리뷰 반영, artifact SHA256 및 증거 요약 저장.
- [ ] 모든 실기기 gate: NOT_RUN. [실기기 절차](../../udp-ipv6-device-acceptance.md)를 마지막에 수행.

DNS 응답이 MTU 허용 payload 1232 bytes를 넘으면 현재 C 경로는 거부한다. IPv4-only에서 실제 answer section에 AAAA가 섞인 ANY 응답은 보수적으로 NODATA 처리하며, 추가/권한 section의 AAAA glue는 정상 응답을 제거하지 않는다. 이 제약은 실기기 관측과 별개다.

자동 검사 로그는 `build/evidence/2026-09-23-extensions/`에 보관한다. 빌드 성공, 실기기 검증, 릴리스 배포를 구분한다. 이번 작업은 기존 작업 branch와 worktree를 보존하며 설치·배포하지 않는다.
