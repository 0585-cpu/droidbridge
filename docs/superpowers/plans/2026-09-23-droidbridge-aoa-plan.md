# DroidBridge AOA Implementation Plan

> 구현은 `superpowers:executing-plans` 및 테스트 우선 절차로 진행한다.

**Goal:** USB debugging 없이 AOA로 기존 pairing/TCP/DNS relay를 사용할 수 있게 한다.

**Architecture:** Mac AOA bulk transport + loopback multiplex bridge, Android accessory foreground service + 고정 loopback service proxy. 기존 DBP 인증 및 helper fail-closed 유지.

**Tech Stack:** Swift 6, C/libusb, Kotlin/NIO, Android UsbManager, 기존 utun helper.

**Spec:** [AOA 설계](../specs/2026-09-23-droidbridge-aoa-design.md).

## Global Constraints

- 기본 전송 AOA; ADB는 개발용. macOS 14+ Apple Silicon, Android API 26+, root 불필요.
- DBAM header 16 bytes, frame payload 최대 16384, stream credit 65536, 동시 stream 최대 256, writer queue 최대 1024.
- stream destination은 relay/pairing loopback뿐. 기존 DBP/SAS 인증 유지.
- 기존 Tetrd·ADB 연결이나 기기 설정을 시험을 위해 자동 해제하지 않는다.

## Review Focus

- USB 재열거 시 같은 port의 기기만 선택하고 다른 폰에 자동 연결하지 않는다.
- credit 초과·malformed·지연 frame·stream ID 재사용을 거부한다.
- TCP half-close 및 pending write 중 detach를 보존/정리한다.
- pairing 전 accessory 연결과 반복 Start가 중복 relay listener를 만들지 않는다.
- 배포 앱이 Homebrew 없이 libusb를 로드하고 helper는 USB 라이브러리에 의존하지 않는다.

### Task 1: DBAM 계약과 양쪽 codec

- [x] Swift/Kotlin에 literal wire 및 split/truncated/oversize/invalid-service 검증을 먼저 추가하고 실패를 확인한다.
- [x] `macos/USB` 패키지와 Android `usb/AoaFrame.kt`에 엄격한 codec을 구현한다.
- [x] 양쪽 테스트로 같은 header/payload 경계를 검증한다.

### Task 2: Mac USB transport와 multiplex proxy

- [x] loopback 실제 socket을 이용한 OPEN/DATA/WINDOW/FIN/CLOSE 및 detach 회귀시험을 작성한다.
- [x] libusb C wrapper에 enumeration, explicit switch, re-enumeration, interface claim, bulk IO, timeout/close를 구현한다.
- [x] Swift bridge에 loopback listeners, stream map, credit/backpressure, bounded writer, disconnect 정리를 구현한다.
- [x] USB 없이 fake byte transport에서 실제 socket echo를 통과시킨다.

### Task 3: Android accessory service

- [x] Java stream과 실제 loopback server로 multiplex·half-close·잘못된 service/credit 시험을 작성한다.
- [x] NIO local socket proxy, UsbManager permission/FD lifecycle, foreground attach/detach를 구현한다.
- [x] manifest accessory filter 및 UI 상태를 연결한다. Start를 idempotent하게 만든다.
- [x] pairing tests의 production port 의존성을 제거하고 unit/lint/assemble을 검증한다.

### Task 4: 제품 기본 경로·패키징

- [x] HostApp의 device discovery/Pair/Prepare를 AOA transport로 연결한다. 기존 인증·helper API를 보존한다.
- [x] bundle libusb 복사·서명 및 라이선스를 추가한다. dependency가 helper로 전파되지 않게 한다.
- [x] 기존 계획과 README를 AOA 우선 순서로 갱신한다.
- [x] macOS Shared/helper/USB checks, 전체 앱 빌드 및 서명 검증을 수행한다.

### Task 5: 검토·실기기 인계

- [x] 전체 변경을 별도 리뷰하고 중요한 결함을 수정·회귀시험한다.
- [x] Android APK와 Mac 앱, 설치/USB mode 전환/페어링/릴레이 시험 절차를 준비한다.
- [ ] Tetrd 연결을 전환할 수 있는 시점에 실제 연결·TCP/DNS·분리/재연결·화면 꺼짐을 검증한다. 미실행 항목을 명시한다.

## 검증 결과 (2026-09-23)

- macOS Shared 164개, helper 10개 및 operation-lock signal 검증 통과.
- USB codec·제어 요청·실제 loopback multiplex·256-KiB 양방향/half-close·ZLP·포트 충돌 사전 차단 검증 통과.
- Android 단위 테스트 90개, lint, APK 통과. IPv6 우선 JVM에서 production relay/pairing 테스트도 통과.
- C/foundation 통과, Python 26개 중 5개 기기 의존 항목은 기존 skip.
- 서명 Host 앱 및 비활성 NE target 빌드 통과. libusb minos 14.0, 앱/라이브러리/helper 서명과 LGPL license/source 포함 확인.
- USB 기기 열거만 실행했고 현재 Tetrd 연결을 claim하거나 모드를 전환하지 않았다. 실기기 acceptance는 미실행.
- 별도 전체 리뷰에서 Android IPv6 loopback mismatch와 USB aligned-tail ZLP 누락을 수정했다. 추가 포트 충돌 회귀시험이 드러낸 NWListener 실패 상태 판정도 수정했다.
- macOS 27에서 기존 helper journal의 completeFileProtection 저장 실패를 재현하고 0600 POSIX atomic journal로 수정했다. 교체와 파일 권한 회귀시험을 통과했다.

사용자 결정: 현재 Tetrd 연결을 유지하고 빌드만 준비한다. 실기기 전환은 이번 작업에서 수행하지 않는다.
