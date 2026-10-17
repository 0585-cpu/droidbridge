# DroidBridge AOA 전송 설계

사용자가 AOA 방식을 선택했다. 기본 제품 경로를 ADB에서 Android Open Accessory로 전환한다. 기존 TCP/DNS, Android cellular binding, DBP 인증, SAS 페어링, utun/configd/pf 보호는 유지한다. 일반 UDP·QUIC와 TTL·트래픽 프로필 개발은 후속 범위로 유지한다.

## 전송 경계

Mac host 앱이 libusb로 사용자가 선택한 USB 기기를 AOA로 전환하고 bulk IN/OUT을 소유한다. 앱의 loopback 전용 listener가 기존 helper의 DBP 연결과 pairing 연결을 AOA 논리 stream으로 전달한다. Android foreground service가 accessory FD를 소유하고 논리 stream을 **127.0.0.1의 relay 또는 pairing 포트에만** 연결한다. 임의 host/port를 wire에서 받지 않는다.

ADB 실행 파일과 USB debugging은 제품 경로의 의존성이 아니다. 기존 ADB 도구는 개발용으로 보존한다. helper는 계속 loopback DBP를 사용하므로 pf 예외 범위를 넓히지 않는다. AOA 연결이나 앱이 죽으면 loopback 세션이 닫혀 기존 health/fail-closed가 작동한다.

## DBAM/1 multiplex

16-byte network-order header: magic `DBAM` 4 bytes, version 1 byte(1), type 1 byte, service 1 byte, reserved 1 byte(0), stream ID 4 bytes, payload length 4 bytes.

- types: OPEN=1, OPEN_OK=2, DATA=3, FIN=4, CLOSE=5, WINDOW=6, RESET=7, RESET_OK=8, PING=9, PONG=10.
- OPEN service: relay=1 (27183), pairing=2 (27184). 다른 프레임 service는 0.
- stream ID: Mac이 부여하는 1…2147483647 범위의 홀수. RESET으로 시작한 세션 내 재사용하지 않는다.
- OPEN/OPEN_OK/FIN/CLOSE payload 없음. DATA 1–16384 bytes. WINDOW는 4-byte 추가 credit, 1–65536.
- 방향별 초기 credit 65536 bytes. 받은 DATA가 local socket에 쓰인 뒤 WINDOW를 돌려준다. credit 초과 송신/수신은 실패로 처리한다.
- 최대 동시 streams 256. USB writer queue 최대 1024 frames. 초과·malformed는 transport를 닫는다.
- FIN은 TCP half-close를 보존한다. 양방향 FIN이 완료되면 CLOSE 없이 정리하여 반대쪽 대기 중인 쓰기를 취소하지 않는다. CLOSE는 오류/명시적 해제이며 늦은 프레임을 새 stream에 연결하지 않는다.
- RESET/RESET_OK는 stream 0, service 0, 16-byte nonce를 사용한다. Mac이 RESET을 보내면 Android는 기존 stream을 닫고 RESET_OK로 nonce를 돌려준다. Mac은 일치하는 응답 이전의 이전 세션 프레임을 무시한다. RESET은 인증 대체가 아니며 이후 DBP/SAS 검증이 필요하다.
- PING/PONG은 stream 0, service 0, payload 없음. Mac은 2초마다 PING을 보내며 8초 동안 PONG이 없으면 연결을 닫는다. Android는 10초 동안 host 프레임이 없으면 외부 소켓을 모두 닫고 다음 RESET을 기다린다.
- USB mode 전환·재접속마다 stream state를 새로 만든다. DBP 인증과 pairing은 각 논리 stream 내부에서 그대로 수행한다.
- AOA manufacturer/model 문자열은 기기 선택용이며 신뢰 증명이 아니다. 데이터 권한은 기존 DBP secret으로 검증한다.

## 기기 선택과 수명주기

기기 나열은 모드를 바꾸거나 interface를 점유하지 않는다. 사용자의 Pair/Prepare 시에만 선택한 기기에 AOA GET_PROTOCOL(51), identity(52), START(53)을 보낸다. 재열거 후 같은 USB port path를 다시 찾는다. 다른 기기로 자동 전환하지 않는다. 기존 accessory는 명시적 연결에서만 연다. Tetrd 등 다른 앱이 소유한 interface는 강제 분리하지 않는다.

Android는 자체 accessory filter, USB permission, attach intent, detach cleanup을 구현한다. 연결은 foreground service가 소유해 Activity 재생성에 영향받지 않는다. relay Start와 accessory attach는 중복 실행되어도 소켓을 중복 bind하지 않는다.

Mac은 현재 relay port 27183/pairing port 27184를 loopback에만 연다. 이미 다른 프로세스가 점유하면 명확히 실패하며 해당 프로세스/ADB forward를 제거하지 않는다.

## 배포·검증

Mac 앱에 libusb dylib와 라이선스를 포함하고 앱의 서명으로 서명한다. helper에는 libusb를 추가하지 않는다. libusb 1.0.30 원본 소스 archive와 SHA-256을 고정하고 macOS 14 deployment target으로 빌드한다. LGPL 라이선스와 대응 소스를 앱에 포함한다. Homebrew 없이 빌드·실행 가능하다.

검증: 양쪽 codec 동일 wire fixture, malformed/credit/half-close/close 경계, 실제 loopback echo multiplex 및 disconnect, Android unit/lint/build, macOS Shared/helper/USB checks, signed app 검증. 실제 AOA mode switch는 현재 사용 중인 Tetrd를 방해할 수 있으므로 빌드·소프트웨어 검증 이후 별도 기기 시험으로 수행한다. 실기기 미실행을 완료로 표시하지 않는다.

## 현재 구현의 경계

USB port path를 호스트 설정의 기기 ID로 사용한다. 다른 USB 포트나 허브로 옮기면 다시 페어링한다. ID는 신뢰 근거가 아니며 DBP secret이 상대를 인증한다. 손상되거나 중간에 잘린 USB 프레임은 재동기화를 시도하지 않고 연결을 닫는다. 이 경우 케이블 재연결과 Android의 Connect USB가 필요할 수 있다.
