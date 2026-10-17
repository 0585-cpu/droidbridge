# AOA 기기 연결과 검증

AOA는 USB 전송 계층이다. IPv4/IPv6 TCP·UDP, DNS, TTL/Hop Limit과 트래픽 프로필이 구현되어 있다. QUIC은 UDP로 전달하며 실제 HTTP/3 및 회선별 검증은 [실기기 시험표](udp-ipv6-device-acceptance.md)에서 별도로 관리한다. 앱 실행에는 USB debugging, Android root, 기본 USB 테더링 설정이 필요하지 않다.

## 빌드

```sh
make check-macos check-macos-usb
make test-android
DROIDBRIDGE_DEVELOPMENT_TEAM=YOUR_TEAM ./scripts/build-signed-macos.sh
```

- Mac: `build/DerivedData/Build/Products/Release/DroidBridge.app`
- Android 개발 APK: `android/app/build/outputs/apk/debug/app-debug.apk`
- libusb는 앱에 포함되며 macOS 14 이상용으로 빌드한다. 라이선스와 대응 소스는 앱의 `Contents/Resources/ThirdParty`에 있다.

## 첫 연결

1. APK를 휴대폰에 설치한다. 기존 설치와 서명이 다르면 기존 페어링 정보를 백업할 수 없으므로 서명을 맞춘 빌드를 사용한다. 개발 시 ADB 설치는 가능하지만 앱 실행에는 ADB가 필요하지 않다.
2. Tetrd 등 다른 USB 앱을 사용하는 중이면 인터넷이 일시 중단될 수 있는 시점에 해당 앱의 연결을 종료한다. DroidBridge는 다른 앱의 USB interface를 강제 해제하지 않는다.
3. 데이터 케이블로 연결하고 Mac의 DroidBridge를 연다. 기기 목록 표시 자체는 USB 모드를 바꾸지 않는다. Mac에서 해당 기기를 선택하고 **Pair New Mac**을 누르면 AOA로 전환한다.
4. Android의 USB 액세서리 안내에서 DroidBridge를 열고 권한을 허용한다. 앱이 이미 열려 있다면 **Connect USB**를 누른다. Mac은 최대 60초 동안 앱의 응답을 기다린다.
5. Android에서 **Pair New Mac**을 누른다. 코드를 입력하는 방식이 아니다. Android 팝업과 Mac에 표시되는 6자리 코드가 같은지 확인하고, 60초 페어링 창이 만료되기 전에 양쪽 **Approve**를 누른다. 만료되면 양쪽에서 다시 시작한다. Mac에서 **Prepare Relay**로 셀룰러 상태를 확인한 뒤 **Start Tunnel**을 누른다. helper 설치 시 macOS 관리자 승인이 필요하다.
6. 종료는 Mac의 **Stop Tunnel**로 라우팅과 보호 상태를 정상 복원한 뒤 **Disconnect**를 누른다. Android의 **Stop**은 USB 연결도 닫는다.

다른 프로세스가 Mac의 27183/27184 포트를 사용하면 DroidBridge는 모드를 바꾸기 전에 실패한다. 기존 개발용 ADB forward가 있다면 소유자를 확인하여 직접 정리한다. 앱은 이를 자동 삭제하지 않는다.

## 장애와 재연결

- USB 분리, Android 앱 종료, 셀룰러 상실 시 helper는 외부 통신을 차단하는 기존 fail-closed 동작을 유지한다.
- 같은 USB 포트에 다시 연결하고 Android의 USB 권한/앱 상태를 확인한 뒤 Mac의 **Recheck Relay** 또는 **Prepare Relay**, 필요하면 **Reconnect**를 누른다.
- 현재 기기 설정은 USB port path를 사용한다. 포트나 허브를 바꾸면 다시 페어링해야 한다. 같은 포트에 다른 폰을 꽂아도 DBP 인증을 통과하지 못하면 릴레이는 열리지 않는다.
- 다른 앱이 이미 accessory mode를 만들었거나 USB 프레임이 중간에 끊겼다면 케이블을 재연결한다. DroidBridge는 Tetrd의 비공개 프로토콜과 상호 운용하지 않는다.

## 소프트웨어 검증과 남은 실기기 시험

소프트웨어 검증은 동일 wire fixture, split/truncated/oversize/service 검사, AOA 제어 요청 순서, 실제 loopback socket 전달, credit 검증, 256-KiB 양방향 전송과 half-close, 세션 재설정, Android unit/lint/APK, macOS Shared/helper/USB, 서명·배포 라이브러리 검사로 구성한다.

다음은 실제 휴대폰에서 별도로 확인해야 한다. 단위 테스트 통과로 완료 처리하지 않는다.

- [ ] USB debugging을 끈 상태에서 신규 AOA 전환과 권한 승인
- [ ] SAS 페어링과 TCP/HTTPS·DNS 사용
- [ ] 여러 연결 동시 전송, 큰 파일 업로드/다운로드의 무결성·속도
- [ ] USB 분리 시 IPv4/IPv6/DNS 외부 누출 없음과 같은 포트 재연결
- [ ] Mac 앱 재시작, Android 앱 재시작·반복 Start/Stop
- [ ] 화면 잠금·화면 꺼짐·배터리 절약 시 연결 유지
- [ ] 셀룰러 상실/복구, Stop Tunnel 후 기존 네트워크 복원

AOA 지원 여부와 USB 권한 동작은 기기별로 확인해야 한다. 실제 AOA 속도·장시간 안정성은 아직 측정하지 않았다.

참고: [Android accessory API](https://developer.android.com/develop/connectivity/usb/accessory), [AOA protocol](https://source.android.com/docs/core/interaction/accessories/aoa).


## 2026-10-13 다운로드 종료 오류 및 USB 복구 검증

SM_F966N(Android16), AOA accessory+ADB에서 확인했다. 최종 Mac 빌드는 `build/DerivedData-ReliableUSBEOF/Build/Products/Release/DroidBridge.app`이며, Android는 reliable USB APK를 사용한다.

USB 누락은 순번·헤더/본문 무결성·누적 ACK·재전송 계층으로 보강했다. 별도로 Mac NWConnection의 마지막 데이터와 EOF가 함께 오는 경우 종료 표시를 버려 다음 읽기에서 POSIX96 오류가 발생했다. 이 오류가 정상 다운로드를 reset으로 바꾸고 C 엔진에 남은 끝부분을 버렸다. 실제 loopback 재현에서 수정 전 실패, 종료 상태 보존 후 통과를 확인했다.

- Shared304, helper18, Android206 unit tests, Android lint 및 Swift USB 검사를 통과했다. 수정한 두 부분은 독립 검토를 거쳤다.
- 실기기 IPv4/IPv6 각각 Tor DMG176897729bytes를2MiB/s 제한으로84.33초에 완료했다. 이전에는 끝부분 약200KB를 남기고 exit56이었다.
- Native Chrome에서도 같은 파일을 완료했다. 세 파일 SHA256은 모두 `169e30fe19d1cba2582cb29b75df9e76d908f0a5bb84f9e3bfe73c64046910d3`이다. 이는 기존 정상 파일과의 무결성 비교이며 제작자 서명 검증을 뜻하지 않는다.
- 같은 HTTPS 연결을60초 재사용해7/7 HTTP200, 새 연결1개를 확인했다. 관찰 구간에 USB 세션 종료 기록이 없었다.
- 최종 빌드의 Parsec 장시간 사용과 휴대폰 웹·영상 동시 사용은 별도 재검증이 남아 있다.14:22 사용자 확인은 EOF 수정 빌드 이전이다. 다른 기기·장시간 무장애를 보장하지 않는다.

증거: `build/evidence/2026-10-13-reliable-usb-eof-device/`; 실패 비교와 코드 재현: `build/evidence/2026-10-13-reliable-usb-device/`. 별도 client FIN half-close 결함은 구현 계획에 후속 항목으로 기록했으며 이번 EOF 문제의 원인으로 단정하지 않았다.
