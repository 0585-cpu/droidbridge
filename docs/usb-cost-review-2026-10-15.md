# USB 처리 비용 분석 검토 — 2026-10-15

16KB AOA 데이터가 신뢰 레코드 경계와 USB 쓰기 경계에서 나뉘는 문제는 현재 코드와 호스트 재현에서 확인했다. 송신 데이터 상한을 16,288B로 맞추는 것은 우선 적용할 만한 개선이다. 다만 실제 Parsec·다운로드에서 각 경로가 CPU를 얼마나 차지하는지는 아직 측정하지 못했으므로, 이것을 삼성 실행 제한의 주원인으로 확정하지 않는다.

이번에는 제품 코드·설치 APK·연결 설정을 변경하지 않았다. 호스트 검사와 기존 로그 분석을 했고, 휴대폰에서는 대상 앱의 종료 메타데이터만 읽었다. USB 인터넷 재연결 및 휴대폰 계측 테스트는 하지 않았다.

## 재현 결과

기존 Debug 빌드의 AoaFrame, ReliableAccessoryChannel, ReliableUsbRecord, ReliableUsbDecoder, ReliableUsbState 클래스를 호출했다. AOA writer의 청크 분할은 코드와 동일하게 재현했다. 가짜 raw 입출력 경계에서 write 호출을 수집하고 디코딩 후 원본 데이터 일치까지 검사했다. 실제 USB 하드웨어 처리량·CPU 벤치마크는 아니다.

| AOA 데이터 | 헤더 포함 AOA 크기 | reliable DATA 레코드 | raw write 크기 |
|---|---:|---:|---|
| 16,384B | 16,400B | 2개 | 16,384 / 80 / 96B |
| 16,288B | 16,304B | 1개 | 16,384B |
| 1,232B | 1,248B | 1개 | 1,328B |

따라서 최대 크기 프레임의 **소프트웨어 write 호출**은 3→1이 된다. USB의 물리 패킷 수가 3→1이 된다는 뜻은 아니다. 작은 프레임에는 이 크기 변경만으로 쓰기 횟수 감소가 없다. Mac도 16,384B AOA 읽기 상한, 16,384B reliable payload 상한, 16KB bulk 쓰기 분할을 사용한다. 실제 수신 최대값은 유지하고 양쪽 송신 읽기 상한만 줄이면 기존 형식과 호환성을 유지할 수 있다.

근거: `AoaAccessoryBridge.kt`의 readLocal 및 writer, `ReliableAccessoryChannel.kt`의 output 및 raw writer, Mac의 `AoaMultiplexer.swift`, `ReliableUsbTransport.swift`, `AoaBulkWriter.swift`.

## 항목별 판단

### ACK와 WINDOW

서로 역할이 다르다. reliable ACK는 바이트 스트림 전달을 확인하고 AOA WINDOW는 특정 논리 스트림의 소비량과 송신 여유를 갱신한다. 어느 한 계층을 삭제하면 안 된다.

현재도 `ackDue`는 boolean이라 writer가 다음 번 실행되기 전에 도착한 DATA들의 확인은 합쳐진다. DATA 송신 시 ACK를 함께 싣는다. 호스트 검사에서 DATA 16개를 한꺼번에 수신한 경우 ACK 1개, DATA 송신 시 piggyback ACK, ACK 수신 시 추가 ACK 없음이 확인됐다. **ACK가 ACK를 부르는 무한 연쇄는 없다.**

WINDOW는 reliable DATA가 되므로 반대편 확인 비용을 추가한다. Android writeLocal은 내부 while에서 여러 소켓 쓰기를 합친 후 WINDOW 하나를 만든다. Mac도 아직 송신 대기 중인 동일 스트림 WINDOW를 합치는 로직이 있다. 따라서 매 소켓 write 또는 매 DATA당 항상 별도 WINDOW·ACK가 하나씩 나간다고 계산하면 과장된다. 명시적인 시간 기반 지연 ACK는 없으므로 추가 병합 여지는 있다.

개선 시 byte/count 문턱과 짧은 최대 지연을 함께 두고, 손실·중복·수신 공간 부족, 스트림 끝, 통신량이 적은 경우를 검사해야 한다. 500ms는 최초 재전송 간격이며 현재 재전송은 500→1,000→2,000ms로 증가한다. 지연 ACK를 넣으면 Android의 nextWakeAt과 Mac writer의 250ms 대기도 함께 조정해야 짧은 ACK 시한을 보장할 수 있다.

### 스레드와 1바이트 읽기

제시한 파이프라인의 작업 스레드·큐·monitor·selector.wakeup 경로는 존재한다. AoaFrame.read의 첫 바이트 읽기가 ReliableAccessoryChannel에서 ByteArray(1)을 만드는 것도 확인했다. 제거 후보가 맞다. 다만 raw read가 레코드를 합치고 selector가 여러 프레임을 배치로 처리하므로, 패킷마다 정확히 다섯 번 OS 문맥 전환이 발생한다고 단정할 수 없다.

### SHA-256 및 재동기화

송신·수신 각각 헤더와 payload를 해시한다. 그러나 Android decoder는 **magic 8바이트가 일치하는 후보에만 헤더 해시를 계산**한다. 무작위 손상 스트림의 모든 바이트 위치에서 해시하는 것은 아니다. 부분 헤더 검증 결과를 저장하는 코드도 있다. magic이 반복되는 특수 입력은 별도로 측정할 수 있지만 현재 장애 시 그러한 데이터가 있었다는 증거는 없다.

CRC32C는 비인증 무결성 검사의 대안이 될 수 있으나 무조건 같은 보호 수준은 아니다. 현재 128비트로 절단한 SHA 검사와 32비트 CRC의 오류 미검출 특성이 다르고, 양쪽 프로토콜 버전·동시 배포·손상 복구 검사가 필요하다. 또한 Android java.util.zip.CRC32C는 **API 34부터**이며 현재 minSdk는 26이다. 현 휴대폰에서는 사용 가능하더라도 지원 범위 전체에 그대로 호출할 수 없다. 하드웨어 가속 및 실제 속도 이득도 기기에서 확인해야 한다. [Android API 34 추가 클래스](https://developer.android.com/sdk/api_diff/34/changes/pkg_java.util.zip).

호환성을 보존하는 레코드 수 감소, 중간 배열 및 불필요한 digest 결과 할당 감소, 재전송 데이터 작업 재사용을 먼저 평가하고 CRC 교체는 프로파일 결과를 보고 결정한다.

### 루프백과 실행기

Android AOA 브리지가 루프백 RelayServer를 거치는 것은 맞다. 현재 StreamBridge는 최근 설치한 변경으로 복사 작업 자체를 socketReads에서 유지하므로 이전처럼 청크마다 Default로 돌아가지는 않는다. socketReads↔socketWrites 이동은 남아 있다.

1024+1024는 즉시 생성하는 고정 스레드 수가 아니라 IO dispatcher view의 동시 작업 상한이다. 필요에 따라 공유 스레드가 생성되므로 실제 250개 스레드의 원인을 상한만으로 확정할 수 없다. [Kotlin IO dispatcher 설명](https://kotlinlang.org/api/kotlinx.coroutines/kotlinx-coroutines-core/kotlinx.coroutines/-dispatchers/-i-o.html).

같은 실행기에서 쓰면 전환 비용은 줄일 수 있지만, 막힌 쓰기가 읽기 작업의 실행 슬롯까지 점유한다. 기존 읽기·쓰기 분리와 용량 설계를 고려하지 않은 통합·상한 축소는 정지나 굶주림 위험을 만든다. 장기적으로는 비차단 소켓 처리 및 루프백 제거를 함께 설계할 수 있으나, 이번 크기 조정과 분리해서 검토한다.

### 복사

여러 배열 복사는 존재하며 레코드 수 감소로 일부를 함께 줄일 수 있다. 정확한 방향별 횟수는 socket read 병합, 프레임 크기, 재전송 여부에 따라 달라진다. 최신 설치 APK의 UDP association 중간 payload 복사 제거는 이미 반영됐다. 버퍼 재사용 시 송신 큐와 미확인 재전송 레코드가 데이터 소유권을 유지해야 한다.

## 테스트·설치 기록 분리

대상 앱 ApplicationExitInfo에서 다음을 확인했다.

| 시각(KST) | PID / UID | 종료 이유 |
|---|---|---|
| 17:13:55.987 | 12972 / 10536 | PACKAGE UPDATED, installPackageLI |
| 17:14:51.457 | 26190 / 10536 | USER REQUESTED / FORCE STOP, finished inst |

실기기 검사 중 기록된 PID 26190의 프로세스 이름도 io.droidbridge.android였다. 따라서 앱 UID 단위 CPU·전력 집계에 계측 테스트 작업이 포함될 수 있으며 실사용과 분리해야 한다. 단순히 분석에서 테스트 시간대를 제외하는 것만으로 삼성 내부의 과거 누적 집계가 초기화되는 것은 아니다.

반면 **재설치 종료를 크래시로 처리하면 안 된다.** Android는 패키지 업데이트를 별도 종료 이유로 기록하며 실제 기기에서도 구분됐다. 삼성 내부의 CRASH/ANR 집계가 이 종료를 어떻게 취급했는지는 확인하지 못했다. [ApplicationExitInfo](https://developer.android.com/reference/android/app/ApplicationExitInfo#REASON_PACKAGE_UPDATED).

9월 22일 EXCESSIVE_APP_CRASH_ANR 항목의 UID는 **10531**, 현재는 **10536**이다. 당시 원본 크래시·계측 기록이 없으므로 해당 항목을 테스트 탓 또는 현재 실행 제한 원인으로 연결할 근거는 부족하다.

최근 16:59:25~17:04:25 관찰은 계측 테스트 종료 및 설치와 별도 구간이고 17:02경 실사용 프로세스에서 abnormal/FROZEN이 직접 수집됐다. 그러나 15초 CPU 프로파일은 이미 제한에 들어간 후 11개 표본만 수집해, 원인별 CPU 순위를 매길 수 없다.

## 다음 수정 순서

1. 양쪽 송신 읽기 상한 16,288B 정렬. 기존 최대 수신·와이어 형식 유지. 손실·양방향·작은 프레임 회귀 검사.
2. WINDOW 병합 및 짧은 지연/누적 ACK. 평균 크기, DATA/WINDOW/ACK 개수, raw write 개수, 재전송 및 지연을 내용 없이 집계해 전후 비교.
3. 1바이트 읽기 할당, 중간 복사 및 불필요한 wakeup 감소. 테스트 부하와 실사용 분리.
4. 제한 진입 전 프로파일로 해시·소켓·스케줄러의 실제 CPU 비중 확인. 필요하면 CRC 변경과 루프백/실행기 재설계를 별도 수행.

근거 파일: `build/evidence/2026-10-15-usb-cost-review/UsbCostProbe.java`, `probe-results.jsonl`, `target-exit-metadata.txt`, `historical-samsung-app-event.txt`.
