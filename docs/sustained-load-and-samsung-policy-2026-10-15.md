# DroidBridge 지속 부하와 삼성 실행 제한 조사

2026년 10월 15일, 설치된 최신 APK와 Samsung SM-F966N의 기록을 조사했다. **삼성의 실행 제한이 먼저 시작되고, USB 지연과 재전송이 늘어난 뒤 Mac의 상태 확인이 실패하여 연결을 종료하는 경로는 확인됐다.** 발열 관련 기록도 함께 확인됐지만, 삼성의 대상 앱 선정 기준과 최초 제한을 유발한 함수별 CPU 비중은 확정되지 않았다.

이번 조사는 기존 로그 분석, 현재 상태 조회, 30초 CPU 카운터 측정과 소스 검토로 진행했다. 앱 소스·설치본·라우팅·전원 및 열 보호 설정은 변경하지 않았다. 트래픽 내용과 인증 자료는 수집하지 않았다.

**장애 시각과 실행 제한**

| 시각 KST | 확인된 기록 | 해석 |
| --- | --- | --- |
| 14:36:54–14:41:54 | Parsec과 휴대폰 동시 사용 중 앱 CPU 평균 26.48%, 최대 표본 37.46%. HTTPS 30회 성공 | CPU 100%는 한 코어를 뜻한다. 휴대폰 전체 사용률이나 동일 조건 전후 개선율이 아니다. |
| 14:41:54 | 삼성 SSRM 내부 열 관리 기록에 `SEVERE` | 삼성 내부 단계다. Android Thermal API의 동일 이름 단계와 직접 대응한다고 가정하지 않는다. |
| 14:41:55 | 같은 앱 PID에 `Slowdown : true` | 5분 관찰 종료 약 1.25초 뒤 제한이 시작됐다. 짧은 검증 성공으로 장시간 안정성을 판단할 수 없었다. |
| 14:42:39 | Mac HEALTH 네 번째 실패, `action=block` | 휴대폰의 응답 지연을 복구 불가능한 상태로 처리했다. |
| 14:43:56 / 14:47:56 | SLOWDOWN 해제 / 재발 | 제한은 반복됐다. 두 번째 진입 무렵에도 삼성 내부 기록은 `SEVERE`였다. |
| 14:49:36 | 앱의 freezer·cpu·cpuset 모두 `/abnormal`, freezer `FROZEN`; HAL 열 상태 2, SKIN 보고값 42.3°C | 프로세스가 살아 있는 상태에서 실행이 제한됨을 직접 확인했다. 이 센서 보고값이 SSRM 발동 임계값이라는 뜻은 아니다. |
| 14:53:33–14:53:59 | Mac USB 누적 재전송 2,568→3,833 | 약 25.8초 동안 1,265개, 초당 약 49개 레코드가 재전송됐다. 휴대폰 측 재전송 횟수와 구분한다. |
| 14:53:51 | HEALTH 네 번째 실패 후 TCP 13개와 UDP association 2개 종료 | Parsec 연결을 포함한 통신을 유지하지 못했다. |

근거: [재발 사건 기록](~/.codex/worktrees/aoa-transport/droidbridge/build/evidence/2026-10-15-postfix-recurrence-1448/incident.json), [당시 휴대폰 상태](~/.codex/worktrees/aoa-transport/droidbridge/build/evidence/2026-10-15-postfix-recurrence-1448/phone-state.json), [Mac 재전송 및 종료 기록](~/.codex/worktrees/aoa-transport/droidbridge/build/evidence/2026-10-15-postfix-recurrence-1448/mac-latest.log), [삼성 열 단계와 대상 앱 제한 기록](~/.codex/worktrees/aoa-transport/droidbridge/build/evidence/2026-10-15-sustained-load-research/ssrm-thermal-and-target-timeline.txt).

**일반 절전과 삼성의 별도 제한**

현재 상태 조회에서는 `connectedDevice` 포그라운드 서비스가 정상 등록되어 있고, target SDK는 36이다. `cached=false`, ActivityManager의 `isFrozen=false`, standby bucket은 ACTIVE에 해당하는 10, 백그라운드 실행 app-op은 allow였다. 기기는 전원에 연결되어 있었고 Doze의 device-idle 및 light-idle 상태는 모두 false였다. 그럼에도 삼성 `/abnormal` 그룹 소속은 유지됐으며, 15:08 표본에서는 `FROZEN`이었다. 같은 표본의 Android 열 상태는 1, SKIN 보고값은 39.5°C였다.

따라서 이번 장애를 단순한 캐시 앱 동결이나 미사용 앱 절전으로 설명할 수 없다. Android의 표준 cached-app freezer는 캐시 상태 프로세스의 실행을 멈추는 기능이다. 여기서 관찰한 것은 캐시 상태가 아닌 포그라운드 서비스 프로세스에 대한 삼성 측 제한이다. ActivityManager의 `isFrozen=false`만 확인하면 이 제한을 놓칠 수 있다. [AOSP cached apps freezer](https://source.android.com/docs/core/perf/cached-apps-freezer), [Android standby bucket 정의](https://developer.android.com/reference/android/app/usage/UsageStatsManager#STANDBY_BUCKET_ACTIVE).

삼성의 공개 앱 관리 문서는 sleeping·deep sleeping·never sleeping 설정과 정상적인 포그라운드 서비스 지원을 설명한다. 이 예외 설정을 SSRM 열 제한 면제라고 설명하지는 않는다. 따라서 ‘절전 예외 등록’이나 WakeLock 추가만으로 이번 문제가 해결된다고 할 근거는 없다. WakeLock은 기기 suspend 방지를 위한 기능이며, 이미 실행 제한을 받은 프로세스에 CPU 실행을 보장하는 수단으로 취급해서는 안 된다. [Samsung Application Management](https://developer.samsung.com/mobile/app-management.html), [Android WakeLock 안내](https://developer.android.com/develop/background-work/background-tasks/awake/wakelock/).

Android는 제조사가 열 상태에 따라 성능을 제한하고 앱이 열 상태 알림을 받아 작업량을 줄이는 구조를 제공한다. 삼성의 Performance SDK 역시 제한을 무조건 해제하는 API가 아니며, 하드웨어 보호를 위해 요청이 거부될 수 있다고 안내한다. [AOSP Thermal mitigation](https://source.android.com/docs/core/power/thermal-mitigation), [Samsung Performance SDK FAQ](https://developer.samsung.com/galaxy-performance/faq.html).

삼성 내부 기록에는 DroidBridge가 주요 CPU 기여 앱으로 포함된 `OVHT` 진단도 있었다. 하지만 앱별 선택 조건, CPU 집계 방식, 제한 유지·해제 조건은 이번에 확인한 공개 공식 문서에서 찾지 못했다. 덤프의 `CPU_USAGE_THRESHOLD=80`, `SlowdownTime=200`, `OVHT_REASON=17`을 곧바로 ‘CPU 80%에서 200ms 정지’ 같은 규칙으로 해석할 수 없다. 다른 정책의 설정값일 수 있으며 단위와 연결 관계가 검증되지 않았다. 열 상태가 낮아진 뒤에도 제한이 남는 관찰 역시 단일 온도 기준으로 설명되지 않는다.

**지속 부하를 만드는 코드 경로**

현재 전송 경로는 셀룰러 소켓 → 앱의 UDP/TCP 중계 → 루프백 소켓 → AOA 프레임 → 신뢰성 레코드 → USB로 이어진다. 각 단계에서 복사, 메모리 할당, 대기열 전달, 스레드 깨우기 및 무결성 검사가 발생한다. 이는 지속 트래픽에 비례하는 비용이다. 아래는 실제 코드에 존재하는 비용이며, 각 항목의 CPU 점유율 순위는 측정되지 않았다.

| 조사 우선순위 | 확인한 비용 | 적용 범위와 다음 확인점 |
| --- | --- | --- |
| 1 | USB 재전송 시 레코드를 다시 인코딩·복사·해시 검사하고, 받은 중복 데이터도 검증 및 복사 뒤에 순서 번호로 제외한다. 미확인 레코드는 최대 32개, 재전송 간격은 500ms다. | 제한 이후 부하 증폭 경로다. 최초 SLOWDOWN의 원인으로 단정하지 않는다. 재전송 간격 적응과 작업 재사용을 검토하되 ACK 갱신·무결성·순서 보장을 유지해야 한다. |
| 2 | UDP 수신 데이터가 association 배열, AOA 배열, reliable 저장 및 인코딩 배열을 거치며 반복 복사된다. 프레임마다 selector를 깨우고 WINDOW 제어 프레임도 만든다. | Parsec 같은 지속 UDP 트래픽에서 확인할 핵심 경로다. 실제 복사 횟수는 루프백 읽기 병합 정도에 따라 달라진다. |
| 3 | IPv6 UDP 업로드의 목적지 검증에서 패킷마다 `getLinkProperties()`를 최대 두 번 호출한다. | IPv6 업로드에 해당한다. 당시 Parsec 트래픽의 IP 버전은 확인하지 않았으므로 이번 원인으로 연결하지 않는다. 네트워크 세대와 변경 콜백에 묶은 속성 스냅샷으로 줄일 여지가 있다. |
| 4 | TCP 중계는 여전히 Default dispatcher에서 읽기·쓰기 dispatcher로 청크마다 이동한다. | 직전 UDP 작업자 개선에 포함되지 않은 경로다. 실제 TCP 처리량과 청크 수를 먼저 측정해야 한다. |
| 5 | 16,384바이트 AOA 데이터는 헤더 포함 16,400바이트가 되어 reliable 레코드 두 개로 나뉜다. 현재 경로에서는 외부 헤더와 USB 쓰기 상한 때문에 raw write 세 번이 필요하다. | 꽉 찬 AOA 프레임에 대한 코드상 결과다. 작은 UDP 프레임이 많은 경우 영향은 다를 수 있다. USB 전송 상한을 보존하면서 프레임 크기를 정렬할 여지가 있다. |
| 6 | 속도 제한이 0이어도 방향별 Mutex와 token-bucket 동기화에 진입한다. UDP peer 만료 목록도 패킷마다 검사한다. | 실제 contention과 peer 수를 확인해야 한다. 보안상 응답 허용 peer 검증 자체는 유지해야 한다. |

관련 코드: [USB 재전송 상태](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/usb/ReliableUsbState.kt), [USB 송수신](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/usb/ReliableAccessoryChannel.kt), [레코드 인코딩](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/usb/ReliableUsbRecord.kt), [UDP association](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/relay/UdpAssociationRelaySession.kt), [셀룰러 정책 검사](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/network/CellularNetworkController.kt), [Android 네트워크 속성 조회](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/network/AndroidCellularTransport.kt), [TCP 중계](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/relay/StreamBridge.kt), [AOA 처리](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/usb/AoaAccessoryBridge.kt), [속도 제한 정책](~/.codex/worktrees/aoa-transport/droidbridge/android/app/src/main/java/io/droidbridge/relay/RelayTrafficPolicy.kt).

현재 소스에서 대기 중 CPU를 계속 점유하는 무한 반복은 확인되지 않았다. 빈 UDP 큐는 suspend하고, AOA writer는 큐에서 대기하며, reliable writer는 다음 작업이나 재전송 시점까지 기다린다. 10초 무진행 종료도 유지된다. 다만 ACK가 간헐적으로 진행하면 종료 시한이 갱신되어 재전송 구간이 길어질 수 있다. 이전에 수정한 반복 Keystore 접근, 무조건적인 진단 해시, decoder 배열 연결 비용을 현재 미수정 문제로 다시 계산해서는 안 된다.

Mac이 대체 Wi-Fi를 사용하는 동안 추가 트래픽을 만들지 않고 30.55초 측정했을 때 앱 CPU 시간은 0.15초, 한 코어 기준 약 0.49%였다. 관찰 중 스레드 생성·종료는 없었다. 단, 삼성 제한 그룹에 남아 있던 표본이므로 제한이 없는 정상 유휴 상태의 기준값이나 무한 반복 부재의 증명으로 쓸 수 없다. [현재 CPU 측정](~/.codex/worktrees/aoa-transport/droidbridge/build/evidence/2026-10-15-sustained-load-research/idle-cpu-analysis.json).

49Hz·30초로 제한한 simpleperf 함수 표본 수집은 시스템 속성 설정 권한 오류로 시작하지 못했다. 우회 설정은 적용하지 않았다. 따라서 SHA 처리, 복사, 스케줄러, 소켓 호출 중 무엇이 현재 CPU의 대부분을 차지하는지는 아직 측정되지 않았다. [프로파일러 결과](~/.codex/worktrees/aoa-transport/droidbridge/build/evidence/2026-10-15-sustained-load-research/simpleperf-attempt.txt).

**복구와 부하 개선의 다음 순서**

1. Mac의 일시적 통신 장애 후 복구 경로를 보강한다. 현재 `HelperService.monitorRelay`는 네 번째 실패에서 종료되므로, USB 세션이 그대로인 채 삼성 제한만 풀리면 확인을 재개하지 않는다. 낮은 빈도의 인증된 재확인을 유지하되 사용자 중지와 세대 변경을 존중해야 한다. 이 개선은 재연결 조작을 줄이는 것이며, 이미 끊어진 Parsec 세션의 무중단 유지나 발열 해결을 보장하지 않는다.
2. 비교 가능한 Parsec 트래픽으로 제한 진입 전 60–90초를 측정한다. CPU/초뿐 아니라 패킷 1,000개당 CPU, 전송 MiB당 CPU, IP 버전·방향, DATA/WINDOW 비율, 평균 레코드 크기, 새 전송/재전송 비율을 함께 기록한다. 패킷 내용은 기록하지 않는다. SLOWDOWN 이후 구간은 정상 처리 비용과 분리한다.
3. 측정으로 확인한 상위 비용부터 복사·프레임 및 깨우기 횟수를 줄인다. IPv6 속성 조회와 무제한 속도 정책의 불필요한 잠금은 조건별 회귀 검증을 갖춰 별도로 개선할 수 있다. 디버그 APK와 실제 배포 설정의 성능 차이도 같은 트래픽으로 비교한다.
4. 앱에 열 상태 관찰과 작업량 조절을 설계한다. 현재 앱에는 Thermal API에 따른 작업량 조절이 없다. Android는 열 상태 callback과 headroom 조회를 제공하며, headroom 조회는 10초보다 자주 하지 않도록 안내한다. 대용량 전송량을 줄일 때 실시간 UDP 지연, 제어 응답, 인증과 데이터 순서가 훼손되지 않도록 별도로 검증한다. [Android Thermal API](https://developer.android.com/games/optimize/adpf/thermal).
5. 식은 기기에서 시작하는 Parsec 단독 구간과 휴대폰 동시 사용 구간을 각각 장시간 비교한다. 삼성 제한을 해제하거나 강제로 CPU 성능을 높이는 방식은 비교 조건에 포함하지 않는다. 같은 환경·트래픽·빌드·충전 상태를 기록하고 자연 발생한 제한과 복구를 확인한다.

코드 비용 감소, 열 상태 대응, 제한 해제 후 복구는 서로 다른 문제다. 세 가지를 나눠 검증해야 짧은 다운로드 성공을 전체 문제 해결로 오인하지 않는다.
