# 2026-09-28 실기기 검증

## 환경

- Android: Samsung SM-F966N, Android 16 / API 36. ADB 디버깅 활성 상태에서 설치·계측했다.
- Mac: 기본 인터넷 경로 Wi-Fi/en0. Tetrd를 종료하고 USB 모드를 초기화한 뒤 DroidBridge AOA 전환을 시도했다.
- 기준 커밋: `8392c6f`. 아래 검사는 이 커밋에 당일 UDP 송신 및 페어링 화면 수정을 적용한 빌드에서 실행했다.
- 초기 빌드·Mac 실행 파일 해시: `build/evidence/2026-09-28-device/preflight.json`.
- 수정 APK SHA256: `a88a2d0970a75780bcdfc024d26f0a3403c6e808c160e712473cd027931ad392`.
- 계측 APK SHA256: `34808f1c5cb49cce4d6ac32e8e3083dad836c3268ebd21918314bfc33b40cbdc`.
- 최종 Mac ZIP SHA256: `cbb6dc9fae22cde1a784a10887ac1580f798f15f2d395b3d3987daed244d168a`.
- 설치된 Helper와 최종 앱에 내장된 Helper의 SHA256이 일치한다. 최종 아티팩트·크기는 `build/evidence/2026-09-28-device/artifacts.json`에 기록했다.

## 확인 결과

| 검사 | 결과 | 범위·근거 |
| --- | --- | --- |
| libusb 장치 검색 / GET_PROTOCOL | PASS | 후보 1대, AOA protocol 2. `aoa-enumerate.log` |
| 실제 AOA 전환 | PASS | 삼성 일반 USB에서 Google accessory `18d1:2d01`로 전환. Android accessory manufacturer/model이 DroidBridge / DroidBridge USB임을 확인 |
| AOA 페어링 hello / SAS 교환 | PASS | Mac에 6자리 SAS 표시. 승인 완료와는 별도 |
| 양쪽 승인·페어링 저장 | PASS | 승인 UI 수정 후 사용자가 양쪽 코드 일치·승인을 완료. Mac의 Prepare Relay에서 인증된 LG U+ 셀룰러 상태 확인 |
| TCP TTL 1/64/65/255 되읽기·FD 수명 | PASS | 실제 Android 소켓 옵션 적용 후 loopback TCP 송수신 |
| IPv6 UDP Hop Limit 1/64/65/255·빈 패킷 | PASS | 수정한 실제 송신 소켓 사용 |
| IPv4/IPv6 UDP 경계·연결 대상 검사 | PASS | 빈 패킷, 일반 패킷, 소켓 종료·다른 목적지 거부 검사 |
| 실제 UdpRelaySession IPv4/IPv6 왕복 | PASS | 0/1/1232-byte 데이터그램 경계·내용을 양방향 확인. 휴대폰 loopback 시험이며 USB/셀룰러 왕복 시험은 아님 |
| 셀룰러 바인딩 TCP | PASS | TRANSPORT_CELLULAR 확인 후 고정 시험 목적지 TCP 연결 |
| 셀룰러 바인딩 UDP DNS | PASS | 선택한 셀룰러 회선 DNS 서버로 직접 UDP 질의·응답, IPv4 |
| 회선 주소군 관찰 | OBSERVED | IPv4·IPv6 link 존재, IPv6 available=true, NAT64 prefix 없음 |
| Helper 교체·전체 Mac 터널 | PASS | IPv6 설정 명령 수정 후 utun4 시작. IPv4·IPv6 기본 경로와 시스템 DNS가 모두 터널을 가리킴. ADB forward 목록은 비어 있음 |
| Mac → AOA → 셀룰러 DNS | PASS | 가상 DNS `198.18.0.1`에서 고정 시험 이름 A 응답, NOERROR |
| Mac → AOA → 셀룰러 HTTPS | PASS | `curl -4` 및 `curl -6`, 모두 HTTP 200. `tunnel-smoke.json` |
| Mac → AOA → 셀룰러 일반 UDP | PASS | IPv4/IPv6 UDP 123 NTP 요청/응답 48 bytes, 응답의 원본 타임스탬프 일치. 단일 요청 RTT 약 84/103 ms로 성능 보증 수치는 아님. `udp-aoa-ntp.json` |
| 실제 HTTP/3 / QUIC | PASS (smoke) | 격리된 venv의 aioquic 1.3.0, 인증서 검증 활성화. IPv4·IPv6 각각 ALPN `h3`, HTTP 200, 약 85 KB 본문 수신. TCP fallback 없음. `http3-results.json` |
| HTTP/3 10 MiB 단일 전송 | BLOCKED_ENDPOINT | 별도 공개 시험 서버가 handshake에서 QUIC 오류 296으로 종료. 터널과 Wi-Fi 직접 연결에서 동일하게 재현. 대용량 gate는 통과 처리하지 않음. `http3-large-{tunnel,wifi}.json` |
| 정상 Stop Tunnel 복원 | PASS | 기본 IPv4 경로·DNS가 Wi-Fi로 복원, 기존과 같이 IPv6 default 없음. utun4·DroidBridge configd service key·recovery journal 없음, HTTPS 200 재확인. `restore.json` |
| API 26–28 / NAT64 / USB debugging OFF | NOT_RUN | 이번 기기·환경 범위 밖 |
| 프로필 UI·DNS 필터·속도 제한 부하 | NOT_RUN | 이번에는 OS 기본 프로필로 Mac 터널 검사. TTL/Hop Limit의 실제 소켓 검사는 별도로 통과 |
| 고부하·장시간·USB 분리·셀룰러 상실·크래시 복원 gate | NOT_RUN | 정상 Stop 검증 및 짧은 통신 성공으로 대체하지 않음 |

## 재현한 문제와 수정

### 연결된 소켓의 빈 UDP 송신 누락

초기 `SocketPolicyInstrumentedTest`의 IPv6 빈 UDP 수신이 timeout으로 실패했다. 24개 조합으로 분리한 결과, IPv4/IPv6 및 소켓 정책 적용 여부와 관계없이 **연결된 Java DatagramSocket의 0바이트 송신 4개 조합만 실패**했다. 미연결 Java 송신, 1바이트 송신, 직접 `Os.sendto`는 모두 수신됐다. 실제 `UdpRelaySession`에서도 수정 전 IPv6 송신 실패를 확인했다. 이후 AOA 전환으로 ADB 출력이 끊겨 두 번째 IPv4 RED 검사는 결과가 남지 않았다.

AndroidCellularTransport에서 생성하는 소켓은 연결된 빈 데이터그램만 공개 `Os.sendto` 경로로 보낸다. 연결 대상 검증·셀룰러 바인딩을 유지하며, 일반 데이터그램은 기존 Java 경로를 사용한다. FD wrapper는 소켓당 하나만 유지하고 원본 소켓 종료 후 정리한다.

수정 후 네 계측 클래스 **9개 검사 모두 PASS**, 건너뛴 검사 없음:

```sh
adb shell am instrument -w -r \
  -e class io.droidbridge.network.SocketPolicyInstrumentedTest,io.droidbridge.network.ZeroLengthDatagramInstrumentedTest,io.droidbridge.network.UdpRelayInstrumentedTest,io.droidbridge.network.CellularBindingInstrumentedTest \
  io.droidbridge.android.test/androidx.test.runner.AndroidJUnitRunner
```

증거: `build/evidence/2026-09-28-device/{socket-cellular,udp-matrix-before,udp-relay-before,udp-cellular-after}.log`.

### 찾기 어려운 페어링 승인 영역

Android의 SAS와 Approve/Reject가 여섯 프로필 입력란 아래에 배치되어 있었다. 승인 대기 상태는 스크롤 밖 AlertDialog로 옮기고, 대기·실패·완료 상태는 Pair New Mac 버튼 옆 영역으로 옮겼다. 승인 조건과 60초 제한은 변경하지 않았다. Mac의 오류 5는 `pairingProtocol`에 해당하며, 코드 교환 뒤 peer 종료 시에도 같은 일반 오류가 표시되는 점을 확인했다.

### Mac IPv6 인터페이스 시작 실패

수정 전 Helper는 IPv6 `/64` 주소와 명시적인 point-to-point 목적지를 함께 `ifconfig`에 전달했고, 실제 시작 시 `ifconfig IPv6 utun4 exited with status 1`로 실패했다. 실패 후 임시 인터페이스가 정리되고 Wi-Fi HTTPS 통신이 정상임을 확인했다.

[Apple XNU의 주소 검증](https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/netinet6/in6.c)은 명시적인 point-to-point 목적지에 `/128`을 요구한다. 명령에서 목적지를 제거해 로컬 `/64`를 구성하고, 기존 configd publication이 같은 prefix 안의 가상 gateway를 사용하도록 유지했다. 수정·재서명·Helper 교체 후 실제 dual-stack 터널 시작과 TCP·UDP·QUIC 통신, 종료를 검증했다.

## 소프트웨어 회귀

수정 후 Android unit tests 126개 PASS, APK 및 계측 APK 빌드 성공, lint 0 errors / 23 nonfatal warnings. Mac Helper checks 12개 PASS, 서명 앱·내장 Helper·libusb 검증 PASS. Android 수정과 Mac IPv6 변경은 각각 독립 리뷰에서 actionable finding이 없었다. 실기기 검사 통과는 통신사 분류·과금 효과 또는 전체 출시 gate 통과를 뜻하지 않는다.

## 최종 상태·빌드

Mac 터널은 중지하고 Disconnect까지 완료했다. 기본 인터넷은 시험 전 Wi-Fi로 돌아갔으며 Tetrd는 시험을 위해 종료한 상태다. 새 페어링과 수정 APK/Helper 설치는 유지한다. 빌드는 다음에 저장했다.

- `build/artifacts/DroidBridge-device-validated-debug.apk`
- `build/artifacts/DroidBridge-device-validated-androidTest.apk`
- `build/artifacts/DroidBridge-device-validated-mac.zip`
- `build/artifacts/DEVICE-VALIDATED-SHA256SUMS.txt`
