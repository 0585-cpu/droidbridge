# Android profileable 빌드·실기기 검증 — 2026-10-15

Release 기반 성능 측정용 APK를 실제 휴대폰에 업데이트했고, CPU 표본 수집도 성공했다. 그러나 10분 실사용 관찰에서는 Parsec 종료와 HTTPS 실패가 재현돼 연결 안정성 검증은 실패했다. 이 빌드는 측정 환경을 개선한 것이며, 연결 장애를 해결했다는 의미가 아니다.

## 빌드와 배포

- Variant: `profileable`, version: `0.1.0-b1-profileable`.
- Release 설정을 상속하고 Java/JNI debugging을 끈다. 별도 manifest에 `<profileable android:shell="true"/>`를 추가했다.
- 기존 application ID와 로컬 개발 서명을 사용한 업데이트로 페어링을 유지했다. 공개 배포용 서명은 아니다.
- Release의 기존 R8 설정(`isMinifyEnabled=false`)은 유지했다. R8 최적화 효과를 측정한 빌드는 아니다.
- debug 전용 화면을 사용하는 UI 테스트 2개를 내용 변경 없이 `androidTestDebug`로 이동했다. 공통 네트워크 테스트는 profileable에서도 실행한다.
- APK: `build/releases/2026-10-15-profileable/DroidBridge-profileable.apk`.
- SHA-256: `7ec53fd207e5c349e0fdd6d7fa26bae8567e9db9dc4a5196fc215310c31edc9a`.
- 설치된 APK의 해시가 일치한다. `run-as`는 “package not debuggable”로 거절됐고 simpleperf는 `app_type=profileable`로 인식했다.

프로젝트 `android` 디렉터리에서 JDK 17을 사용한다.

```sh
./gradlew -PdroidbridgeTestBuildType=profileable testProfileableUnitTest lintProfileable assembleProfileable assembleProfileableAndroidTest
./gradlew assembleDebugAndroidTest
```

첫 instrumentation 빌드는 debug 전용 화면 참조 때문에 실패했다. 위 소스셋 분리 후 전체 명령이 성공했다. 단위 테스트 268개, 실기기 네트워크 테스트 9개가 통과했고, lint는 오류 0개·경고 18개였다. 일반 debug instrumentation APK 빌드도 통과했다.

## 실사용 결과

2026-10-15 **16:27:30–16:37:30 KST**, Samsung SM-F966N / Android 16에서 관찰했다. 사용자는 Parsec과 휴대폰 웹·영상을 사용했으며, 중간 Parsec 재접속으로 부하가 일정하지 않았다. 시작 30초 동안 앱 CPU를 샘플링했고, 별도로 1 MiB/s 제한·45초 제한의 10 MiB HTTPS 다운로드를 1회 실행했다.

| 항목 | 결과 |
| --- | --- |
| 관찰 완료 | 600초, 프로세스 표본 40개 |
| 인터넷 경로 | 40개 표본 모두 USB `utun4` |
| HTTPS | 60회 중 56회 성공, 4회 실패 |
| Parsec 종료 | 16:28:50, 16:33:44 — 두 차례 `-12007` 기록 |
| Mac health 검사 | 통신 차단 4회, 자동 복구 4회 |
| 흐름 정리 | 5회: `stop` 4회, `capabilities-timeout` 1회 |
| 다운로드 | 2,244,581 / 10,485,760 bytes에서 45초 시간 초과, curl exit 28 |
| 삼성 제한 그룹 | 40개 표본 모두 `/abnormal` |
| freezer | 40개 표본 중 22개 `FROZEN` |
| 앱 프로세스 | 표본 내 PID 8820 유지, 스레드 75–188개 |
| thermal status | 초기 1, 마지막 열 상태 표본 2 |
| USB 세션 종료 | 수집한 앱·Mac 로그에서 해당 종료 메시지는 관찰되지 않음 |

HTTPS 실패 횟수는 독립 장애 횟수가 아니다. FROZEN 표본 비율도 전체 시간 중 정지 시간 비율은 아니다. USB 종료 메시지가 없다는 사실만으로 모든 USB 지연 문제를 배제할 수 없다.

## CPU와 원인 해석

시스템 로그에서 **16:27:22.714 `SLOWDOWN::OOM Request PID = 8820, slowdown = true`**를 확인했다. 첫 측정부터 `/abnormal` 및 FROZEN이 관찰됐다. 최초 제한은 CPU 프로파일 수집 시작 약 8초 전이므로, 이 제한의 최초 발동을 프로파일러 실행 탓으로 볼 수 없다.

이어서 USB 재전송이 증가했고, 16:27:54 health 실패로 TCP 25개와 UDP association 15개가 정리됐다. 이후 health 복구와 Parsec 종료가 기록됐다. 이번 결과는 **Release 기반 빌드에서도 실행 제한 → 응답 지연 → 통신 흐름 정리가 재현됨**을 보여 준다. 삼성 정책의 정확한 발동 조건과 앱 부하가 기여한 정도는 아직 분리하지 못했다.

30초 `task-clock:u` / 99 Hz 측정은 CPU 표본 **91개, 손실 0개**였다. 스레드 이름별로 DefaultDispatch 계열 41개, aoa-sockets 12개, reliable writer 10개, reliable retry 9개였다. 큐·코루틴 스케줄링·소켓 처리·USB 무결성 계산 경로가 후보로 보이지만, 단일 함수가 병목이라고 확정하기에는 표본이 적다. 프레임 포인터 호출 스택 해석도 **38개(41.8%)에서 오류**가 있어 완전한 호출 경로 분석으로 볼 수 없다.

관찰 평균 CPU는 코어 1개 기준 5.74%였으나 실행 제한과 통신 중단이 섞인 값이다. 앞선 debug 측정과 부하·온도·제한 상태가 같지 않으므로 CPU 개선율을 계산하지 않는다. 측정 자체의 비용도 처음 30초에 포함된다.

다음 성능 검증에서는 제한이 이미 걸린 상태와 제한 없는 상태를 분리하고, 동일한 트래픽 조건으로 코루틴/스레드 수 증가와 큐·소켓 처리 비용을 비교해야 한다. 삼성 열·전원 보호를 해제해 측정한 결과는 사용하지 않는다.

## 종료 상태와 증거

관찰용 자식 프로세스는 종료됐다. USB 테스트 연결을 앱에서 정상 해제하고 기존 대체 네트워크로 복구했다. **16:39:21 KST에 `en0` 기본 경로와 HTTPS 204 응답을 확인했다.** 새 APK는 휴대폰에 설치된 상태다. 이 작업에서 Mac 앱·도우미는 교체하지 않았다.

전체 근거는 `build/evidence/2026-10-15-profileable/`에 있다.

- `verification.json`, `installed.json`, `apk-signature.txt`: 빌드·서명·설치 확인.
- `profile-summary.json`, `profileable-active.perf.data`, `profileable-active-threads.txt`, `profileable-active-callgraph.txt`: CPU 표본과 해석 한계.
- `live-analysis.json`, `live-installed/summary.json`, `samples.jsonl`, 각 플랫폼 로그: 통신과 실행 제한의 시간대 비교.
- `final-network.json`: 관찰 종료 후 대체 네트워크 확인.
- `reproduction.json`, `changes-this-turn.patch`: 재현 명령과 이번 범위의 변경.

참고: [Android 성능 프로파일링](https://developer.android.com/studio/profile), [profileable manifest 요소](https://developer.android.com/guide/topics/manifest/profileable-element), [Android simpleperf 앱 프로파일링](https://android.googlesource.com/platform/system/extras/+/master/simpleperf/doc/android_application_profiling.md).
