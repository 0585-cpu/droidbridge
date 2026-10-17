# USB 전송 부하 감소 수정 — 2026-10-15

Android와 Mac의 USB 송신 크기, 신뢰 계층 ACK, AOA WINDOW 갱신을 수정했다. 호스트에서 동작·회귀 검사와 빌드·서명 검증을 완료했다. **새 빌드는 설치하지 않았다.** 현재 휴대폰 APK와 `/Applications/DroidBridge.app`은 유지했다. CPU 감소율, 삼성 실행 제한 재발 여부, Parsec 연결 안정성은 이번 빌드로 실기기 측정하지 않았다.

## 적용 내용

| 경로 | 변경 | 보존한 동작 |
|---|---|---|
| 양쪽 AOA 송신 | 소켓 읽기 페이로드 상한을 16,288 B로 설정. AOA 헤더 16 B와 신뢰 레코드 헤더 80 B를 합쳐 16,384 B 쓰기 한 번에 수용 | 수신 허용 크기 16,384 B와 두 와이어 포맷 유지 |
| 양쪽 신뢰 ACK | 첫 미확인 DATA부터 2 ms 또는 8개 DATA에서 누적 ACK 전송. 후속 DATA가 첫 기한을 미루지 않음 | 중복·누락·수신 거절에는 즉시 ACK, 송신 DATA에 ACK 동봉, 기존 재전송·실패 기한 유지 |
| 양쪽 AOA WINDOW | 32 KiB 소비 또는 첫 소비부터 5 ms에 누적 크기 전송 | 작은 요청도 기한에 전송, 기존 2초 반복 갱신, 반닫기·역압 유지 |
| Android 프레임 읽기 | 헤더를 bulk read로 읽어 프레임마다 한 바이트 읽기를 위한 배열 할당과 잠금 진입 제거 | 정상 EOF와 잘린 헤더 오류 구분 |
| 양쪽 신뢰 디코더 | 완성된 레코드가 없는 부분 읽기에서는 대기 스레드 깨우기 생략 | 레코드 수신·종료·송신 큐 변경 시 깨우기 유지 |
| Mac 신뢰 송신 대기 | 고정 250 ms 확인 대신 다음 ACK·재전송·실패 기한까지 대기 | 유휴 상태에서는 신호 대기, 종료 시 해제 |

Android WINDOW는 기존 selector의 대기 기한을 사용한다. Mac은 mux queue의 타이머 하나를 공유한다. 스트림마다 타이머 스레드를 만들지 않는다. 2 ms와 5 ms는 스케줄링 목표 기한으로, 운영체제가 앱 실행을 중지하거나 송신 경로가 막히면 실제 전송은 늦어질 수 있다.

16,288 B는 최대 송신 데이터의 크기다. 모든 작은 패킷이 이 크기로 합쳐지는 것은 아니다. ACK는 누적 확인이므로 묶어도 수신하지 않은 데이터까지 확인하지 않는다. ACK 자체가 다시 ACK를 요구하는 구조도 아니다.

## 검증

- 수정 전 새 ACK/송신 크기 검사에서 의도한 실패를 확인했고, WINDOW 정책 검사도 변경 전 실패를 확인했다.
- Android Debug 전체 검사: 285개, 실패·오류·건너뜀 0. 이후 raw write 통합 검사를 추가한 최종 profileable 전체 검사: **286개, 실패·오류·건너뜀 0**.
- profileable lint: 오류 0, 경고 21. 기존 배터리 예외 권한·wakelock·SDK 및 의존성 갱신 등의 경고를 남겼다. 이 USB 수정에서 관련 설정을 변경하지 않았다.
- Mac `swift run USBChecks`: 전체 통과. 손실·재정렬·중복·재전송·수신 역압·취소·반닫기·WINDOW 손실 복구·막힌 writer 및 다중 스트림 검사를 포함한다.
- 양쪽 실제 로컬 소켓을 사용하는 mux 검사에서 65,536 B의 정확한 전달과 DATA 페이로드 상한을 확인했다.
- 별도 통합 검사에서 Android `ReliableAccessoryChannel`과 Mac `ReliableUsbTransport → AoaWriteTrace → AoaBulkWriter`를 통과시켜 **16,288 B DATA가 16,384 B raw write 한 번**으로 생성되는 것을 확인했다. 실제 USB 장치 대신 기록용 I/O를 사용한 호스트 검사다.
- 독립 코드 검토: 차단할 결함 없음. 최초 검토의 raw write 통합 검사 보강 의견을 반영했고 재검토에서도 새 결함이 없었다.
- 새 Debug APK, profileable APK 및 profileable 계측 APK 빌드 성공. Mac Release 빌드 성공. APK 인증서와 Mac 앱·내장 도우미·libusb 서명 검증 성공.

## 준비한 빌드

모두 `build/releases/2026-10-15-usb-batching/`에 있다.

| 파일 | 용도 | SHA-256 |
|---|---|---|
| `DroidBridge-profileable.apk` | Release 기반, debuggable=false, profileable shell=true. 실제 부하 측정용 | `2a9aa8578413c69acb17c0add7b3747dfc8e602a246e2490c2724eb272b1eee5` |
| `DroidBridge-debug.apk` | debuggable=true. 중단점 등 디버깅용 | `56eb46ee20e34c2d31fd70dcf9f29d671dc911a5108e9526fb72741d933d1f6c` |
| `DroidBridge-macOS.zip` / `DroidBridge.app` | Apple Development로 서명한 Mac Release 빌드 | ZIP: `2c0892b7022a770def4bb44fee33cd25f9b8b614a8feba7de861f3af02c8c3d9` |

두 APK는 기존 개발용 인증서와 같은 패키지(`io.droidbridge.android`)를 사용한다. 두 가지 파일을 준비한 것이며, 같은 휴대폰에 독립 앱으로 동시 설치하는 구성은 아니다. Mac 앱은 로컬 개발 서명 빌드이며 배포용 공증은 수행하지 않았다.

원본 로그·최종 검사 결과·이번 수정만의 패치는 `build/evidence/2026-10-15-usb-batching/`에 저장했다. 기존 작업 트리 변경과 구별하기 위해 수정 전 USB 소스 스냅샷과 비교했다. 결과 요약은 `verification.json`, 검토 결과는 `review.json`, 패치는 `usb-batching.patch`다.

## 다음 실기기 측정

새 빌드 설치 후 같은 Parsec/다운로드 부하에서 CPU, 스레드 수, 재전송, 연결 종료와 삼성 제한 기록을 비교해야 한다. 계측 테스트·설치 시간대는 실사용 측정과 구분한다. 현재 단계에서 끊김 해결이나 삼성 실행 제한 방지를 확정하지 않는다.

CRC32C로의 와이어 포맷 변경, 루프백 제거, 릴레이 dispatcher 통합은 이번 수정에 포함하지 않았다. CPU 프로파일에 근거해 후속 변경의 필요성과 효과를 따로 판단한다. 전원·열 보호 정책은 변경하지 않았다.
