# utun 헬퍼 앱 — 현황과 이어서 할 일 (2026-09-23)

`main` 기준(`faf9b74`)입니다. 유료 Apple 계정 없이 NE 확장 대신 **root utun 헬퍼**로 도는 구조이고, 설계는
[`superpowers/specs/2026-09-22-droidbridge-utun-helper-app-design.md`](superpowers/specs/2026-09-22-droidbridge-utun-helper-app-design.md)에 있습니다.

## 1. 이번에 고치고 실기기에서 검증한 것

| 문제 | 원인 | 수정 | 커밋 |
|---|---|---|---|
| 킬스위치가 목록에 없는 인터페이스(awdl0, 다른 utun, 핫플러그)로 샘 | pf 규칙이 `networksetup` 목록만 막는 default-allow | `block … out all` 기본 거부 | `ea7e8ec` |
| 터널 중 사이트 이름 접속 실패 | 시스템 DNS가 en0의 DHCP 서버를 계속 사용 → pf가 차단 | 아래 네트워크 서비스 방식에 흡수 | `ad52429` → `10b03a1` |
| **핫스팟을 끄면 터널이 죽음** | `route add`로 넣은 기본 경로를 configd가 네트워크 변경 때마다 덮어씀 | 터널을 configd의 **주 네트워크 서비스**로 게시(`OverridePrimary`) | `10b03a1` |
| 터널을 켜는 순간 기존 연결이 멈춤 | `block drop`은 이미 맺어진 연결을 조용히 버려 TCP가 타임아웃까지 대기 | `block return`(즉시 RST) | `bdb5889` |
| **폰 앱을 닫거나 화면을 끄면 릴레이 멈춤** | 포그라운드 서비스가 있었지만 아무도 시작하지 않음 | Start가 FGS를 거치고, 릴레이 인스턴스는 앱 전체에서 하나 | `1cdcf3a` |

검증 근거(요약):
- 핫스팟 OFF 상태에서 터널 혼자 모든 트래픽 처리(주 인터페이스 `utun6`, DNS `198.18.0.1`), 다운로드 9.3MB 중 핫스팟 경유 79B
- 폰 앱 스와이프 종료 + 화면 꺼짐 3분 동안 터널 접속 36/36 성공
- `block drop` 대조군은 기존 연결이 6.00초 멈춤, `block return`은 0.00초 리셋

## 2. 바뀐 구조 요점

- **경로·DNS는 헬퍼가 직접 만지지 않습니다.** `State:/Network/Service/D801B21D-…/{IPv4,DNS}`를 게시하면 configd가 기본 경로와 리졸버를 utun으로 두고 유지합니다. 키를 지우면 configd가 원래 네트워크를 알아서 복원합니다. 사용자 네트워크 설정은 건드리지 않습니다.
  - `macos/Shared/.../Tunnel/TunnelNetworkService.swift` (scutil 스크립트 생성, 순수)
  - `macos/Helper/NetworkServicePublisher.swift` (게시 후 `PrimaryInterface`를 되읽어 확인)
- **fail-closed 순서:** 시작 = pf → 서비스 게시 → 엔진 / 종료 = 서비스 철회 → pf.
- **복구 저널:** `{utun, pfEnableToken}`. 저널이 남아 있으면 설치 스크립트가 헬퍼 교체를 거부합니다(먼저 Stop).
- **Android:** `ServiceBackedRelayController`(UI) → `RelayForegroundService` → `RelayServiceController.shared()`.

## 3. 남은 작업

1. **8.8.8.8 간헐 타임아웃 (원인 미상).** 핫스팟을 끈 뒤에만 가끔 발생합니다. 폰에서 직접 연결하면 되고, 같은 순간 다른 사이트는 되며, 릴레이 거부 로그도 없습니다. 여러 목적지로 반복 측정해 특정 목적지 문제인지부터 가려 보세요.
2. **`PairingServerTest`가 실제 포트 27184를 바인딩합니다.** `adb forward tcp:27184`가 켜져 있으면 실패하므로, 테스트 전용 포트로 분리하는 게 좋습니다.
3. **수용시험(→ `v0.1.0-b1`)**
   - `b1-killswitch`: `usb`만 통과. `relay`/`cellular`/`sleep`이 남았습니다(`cellular`는 핫스팟도 같이 끊김).
   - `b1-stress`(128 플로우), `b1-soak`(1시간, 릴레이 연결 누수 여부도 여기서 판정), `b1-performance`.
   - `b1-functional`은 **맥이 폰 핫스팟을 쓰면 무의미합니다**(터널 ON/OFF 모두 같은 ASN). 다른 통신사/유선 회선에서 해야 합니다.
4. 미관측: 터널 가동 중 핫스팟이 **다시 켜지는** 경우. macOS가 이미 온라인이라 자동 재접속을 안 하는 것으로 보이며 해는 없지만, Wi-Fi 메뉴로 직접 붙여 한 번 확인해 보세요.
5. 충전 없이(배터리) 깊은 절전 상태에서 폰 릴레이가 버티는지는 아직 시험하지 않았습니다. 필요하면 웨이크락을 검토하세요.

## 4. 빌드·검증 명령

```bash
DROIDBRIDGE_DEVELOPMENT_TEAM=ABCDE12345 ./scripts/build-signed-macos.sh   # 서명 빌드
make check-macos && ./scripts/check-macos-helper.sh && make test-core      # 맥 테스트
cd android && JAVA_HOME=<jdk17> ./gradlew testDebugUnitTest installDebug   # 안드로이드
sudo ./scripts/killswitch-check.sh build/DerivedData/Build/Products/Release/DroidBridgeHelper   # 터널 끈 상태
sudo ./scripts/diagnose-tunnel.sh      # 터널 켠 상태 스냅샷 → build/diagnostics/
```

헬퍼 재설치는 앱의 **Start**가 합니다(설치본과 번들의 SHA256이 다르면 자동 교체). 별도 설치 메뉴는 없습니다.

## 5. 함정

- 터널이 켜진 동안 대화형 도구(Claude 등)는 끊길 수 있습니다 → 진단은 스크립트로 파일에 남기고, 끈 뒤에 읽으세요.
- `sudo` 인증은 터미널 탭마다 따로입니다 → `sudo -v && <명령>`처럼 한 줄로 실행하세요.
- zsh에서 `log`는 내장 명령입니다 → 항상 `/usr/bin/log show …`.
- 이 통신사(LG U+)는 **1.1.1.1을 차단**합니다 → 시험 목적지는 `8.8.8.8`, 대기 시간은 릴레이 연결 타임아웃(10초)보다 길게 잡으세요.
- `scutil`은 쓰기가 거부돼도 종료 코드 0입니다 → 출력과 실제 효과로 판정하세요.
- `PairingServerTest` 실행 전 `adb forward --remove tcp:27184`, 끝나면 다시 추가하세요.
