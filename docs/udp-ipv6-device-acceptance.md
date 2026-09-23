# UDP·프로필·IPv6 실기기 검증 대기표

2026-09-23: 사용자 지시에 따라 2·3·4 소프트웨어 구현과 빌드를 먼저 준비한다. 아래 항목은 모두 **NOT_RUN**이며, 현재 Tetrd 연결을 유지한다. 설치·AOA 전환·Helper 교체·실제 경로 변경은 실행하지 않았다.

## 시험 순서

1. 별도 인터넷 경로와 현재 Tetrd 복원 방법을 준비한 뒤 [AOA 절차](aoa-device-acceptance.md)로 장치 권한, pairing, relay, Helper 시작/종료를 검증한다.
2. IPv4 TCP/DNS 회귀와 임의 UDP echo를 시험한다. UDP payload 0/1/1200/1232 bytes는 경계·순서를 보존해야 하며 1233 bytes와 IP fragment는 거부해야 한다. UDP/53은 기존 가상 DNS 경로가 우선한다.
3. 제어 가능한 HTTP/3 서버에서 HTTP/3 지원 curl의 `--http3-only`로 실제 HTTP 버전 3 및 10 MiB 전송을 확인한다. TCP fallback 성공은 이 항목의 성공이 아니다.
4. Android 프로필 OFF/TTL 1·64·65·255, Hop Limit 1·64·65·255를 비교한다. 실행 중 편집은 거부되어야 한다. `app-debug-androidTest.apk`의 소켓 옵션 검사로 실제 적용값과 FD 수명·빈 UDP 전달을 확인한다. Android API 26–28과 최신 기기를 각각 포함한다.
5. DNS suffix 필터 ON/OFF, 대소문자·label 경계, AAAA 억제와 정상 A 응답을 확인한다. 필터는 터널 DNS 경로에만 적용되며 DoH/DoT·직접 IP 접속을 필터링하지 않는다.
6. 방향별 rate/burst를 제어된 부하에서 측정한다. 초기 burst 이후 30초 평균은 회선 용량이 충분할 때 설정률 ±10%, 누적 허용량은 `rate × elapsed + burst` 이하여야 한다. 다운로드 제한은 이미 휴대폰에 도착한 셀룰러 데이터 사용량을 줄인다는 보장이 아니다.
7. IPv4-only, dual-stack, IPv6-only/NAT64 회선에서 IPv6 TCP/UDP, Hop Limit 및 capability에 따라 ICMP Echo를 시험한다. 사용할 수 없는 주소군은 다른 Mac 회선으로 우회하지 않아야 한다.
8. USB 분리·릴레이 종료·cellular 교체·Mac sleep/wake 때 IPv4/IPv6 외부 우회가 없는지 확인한다. 이전 flow는 종료되고 새 flow로 복구해야 한다. 기존 QUIC 세션의 무중단 이동은 제공하지 않는다.
9. B1 1시간, TCP+UDP 2시간, dual-stack mixed 8시간 soak, 100 UDP flow/10분, 최대 flow 정리, 메모리·drop·지연·처리량을 기록한다.
10. Helper 종료·크래시 복구 후 IPv4/IPv6 configd 상태와 pf가 복원되는지 확인한다. 최종 서명·설치·앱 재시작까지 확인한 뒤 실기기 gate를 닫는다.

## 결과 기록

각 결과에는 사용한 Mac/APK SHA256, OS/API/회선 주소군, 시험 시각, 기대값/실측값, PASS/FAIL/NOT_RUN을 남긴다. 자동화 결과만으로 셀룰러 binding, AOA 안정성, 통신사 분류·과금 변화나 실제 QUIC 성능이 입증되었다고 기록하지 않는다. 비밀키·사용자 payload·DNS 이름·일반 목적지 이력은 기록하지 않는다.
