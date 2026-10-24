# Caps Lock 짧은 한영 / 긴 잠자기 방지 전환

## 목표와 범위

MacBook Pro 내장 Caps Lock은 짧게 누르고 떼면 ABC와 한국어 두벌식만 전환한다. 0.8초 이상 누르면 잠자기 방지를 양방향으로 한 번 전환한다. 키를 뗀 뒤 불빛은 확인된 실제 잠자기 방지 상태와 일치해야 한다. 대문자 고정 기능은 사용하지 않는다.

| 입력 | 한영 | 잠자기 방지·불빛 |
| --- | --- | --- |
| 짧게 누름 | ABC ↔ 한국어 두벌식 | 상태 유지 |
| 0.8초 이상 누름 | 유지 | ON ↔ OFF |

대상은 hold controller, raw HID monitor, 입력 소스 전환, 전담 event tap, native key mapper, 앱 lifecycle, 실행·설치 스크립트와 해당 회귀 테스트다. helper 권한과 기존 타이머·단축키·CLI의 명시적 제어는 보존한다. 개인 fork의 같은 브랜치/PR에서 진행하며 merge는 별도 승인 후 수행한다.

## 설계

1. 접근성·입력 모니터링·내장 키보드·ABC/한국어 입력 소스가 모두 준비된 경우에만 전담 매핑을 활성화한다. 내장 Caps 원래 매핑을 사용자 전용 0700 디렉터리/0600 파일에 먼저 동기화해 보관한 뒤 Caps→F18을 적용·검증한다. 다른 키의 매핑과 외장 키보드는 유지한다.
2. F18 down/up은 event tap에서 소비한다. 실제 raw HID Caps press/release의 monotonic timestamp로 길이를 재고 short release만 TIS 입력 소스를 한 번 선택한다. hold는 기존 polling에서도 판정하며 한 번 누른 동안 최대 한 번 전환한다. 키보드 분리·wake·종료 때 오래된 누름을 취소한다.
3. 전원 의도는 실제 SleepDisabled에서 초기화한다. native Caps modifier나 LED 값은 전원 명령으로 사용하지 않는다. helper 성공과 실제 상태 확인 뒤 LED output을 쓴다. 출력 실패를 숨기지 않고 재시도하며 오래된 LED/CLI/타이머 완료가 새 요청을 덮어쓰지 않는다.
4. native uppercase modifier는 OFF로 유지한다. 보안 입력에서 modifier를 ON으로 복구해 불빛을 표현하는 기존 경로를 사용하지 않는다. F18은 실행 중 전담 키로 예약된다.
5. 감독 실행기가 정상 종료·충돌·TERM 후 키 매핑을 복구한다. PID가 다른 새 소유자의 백업은 건드리지 않는다. 복구는 현재 Caps 매핑이 앱 소유 F18일 때만 수행하며 사용자가 새로 바꾼 Caps 및 다른 키 매핑을 보존한다. 복구 실패 시 백업과 복구 binary를 남긴다. 설치 시 복구를 확인한 뒤 앱을 교체한다.
6. 모든 앱 실행 경로는 단일 인스턴스 lock을 사용한다. 정상 종료와 signal 종료 시에는 LED와 잠자기 방지도 OFF로 돌린다. crash 후 전원은 재실행 앱이 실제 상태에서 이어받는다.

## 작업과 검증 순서

1. short/long 분리, 지연 완료, 매핑 보존·rollback·PID·백업 권한, supervisor 종료 경로를 RED로 재현한다.
2. 최소 구현 뒤 전체 Swift suite, shell 구문/lifecycle, release 빌드를 실행한다. 연결된 코드의 독립 검토에서 발견한 설치 백업 삭제·중복 실행·busy 중 짧은 입력 유실을 수정하고 재검증한다.
3. 기존 앱·LaunchAgent·설정을 백업하고 helper와 설정을 보존한 채 수정본을 교체한다. 실제 mapping/권한/doctor와 정상·충돌 복구를 확인한다.
4. 사용자가 실제 키보드에서 짧게 → 길게 → 짧게 → 길게를 눌러 한영과 불빛/잠자기 방지를 확인한다. 같은 개인 PR을 최종 구현/검증 중심으로 갱신한다.

## 검증 현황과 한계

### 실제 잠자기 복귀 회귀 수정

실제 잠자기 후 기존 IOHID event-system client가 키 매핑 쓰기를 계속 거부해 전담 입력이 중단됐다. 같은 앱 재시작은 즉시 복구돼 권한 문제가 아닌 오래된 연결 문제로 좁혔다. 서비스 열거 시 client와 handle을 새로 만들어 복구·활성화가 현재 키보드 연결을 사용하게 한다. 백업·rollback 및 다른 키 매핑 보존은 유지한다.

작업 순서는 실물 실패 기록 → 최소 연결 수정 → 전체 Swift 검사와 release 빌드 → 기존 앱 폴더에 적용 → 실제 잠자기 및 사용자 단/장 입력 재검증이다. 수용 기준은 같은 프로세스의 wake 후 doctor healthy·매핑 active, 짧게 한영만 전환, 길게 잠자기 방지와 키를 뗀 뒤 LED 유지다. 하드웨어 연결 단절은 fake backend 테스트로 증명할 수 없으므로 실제 재시험 결과를 별도로 기록한다. 실제 재시험에서 Sleep Count가 1→2로 증가하고 같은 PID가 유지됐다. wake 후 매핑·hold 준비·doctor 정상, 사용자도 short/long 및 키를 뗀 뒤 물리 LED가 모두 정상이라고 확인했다. 잠자기 방지를 초기 ON으로 복원했고 실제 상태·LED 보고·display-awake assertion을 재확인했다.

- 통과: 최종 `swift test` 235건, 실패 0, 실물 hardware 2건 skipped. release 앱과 unsigned pkg 빌드, 추출된 runner/agent/postinstall, shell 구문, vendor snapshot, CI 변경 감지와 diff 검사를 확인했다.
- 통과: mapping fake/temp-file 22건. 원래 매핑 보존, partial failure rollback, private backup, owner PID와 복구 재시도를 확인했다. x86_64 컴파일과 arm64 타입 검사를 수행했다.
- 통과: fake supervisor 정상 종료·충돌·TERM·복구 실패 전달 4경로.
- 통과: 실제 로컬 설치 후 두 권한 갱신, 전담 mapping/백업0700·0600, doctor healthy를 확인했다. 실제 TERM과 child SIGKILL에서 원래 매핑 복구·백업 제거를 확인했고, crash 뒤 LaunchAgent 자동 재시작과 새 owner PID를 확인했다.
- 통과: 사용자 MacBook Pro에서 짧게→1초 길게→짧게→1초 길게를 실행해 short 한영만 전환 및 전원·물리 LED OFF→ON→ON→OFF가 모두 정상이라고 확인했다.
- 통과: 실제 잠자기 복귀 후 같은 프로세스에서 매핑·단/장 입력·물리 LED 유지. Capsomnia ON 및 keep-display-awake ON, lock-on-lid-open OFF에서 덮개를 닫았다 열어 잠금 없이 복귀함을 사용자 확인했다. 이 설정은 Capsomnia ON 동안 적용되며 OS 전체 암호 요구 정책을 바꾸지 않는다.
- 미검증: Secure Event Input 전체 동작과 실제 재로그인 경로. 로그인 자동 실행 설정과 현재 관리 실행은 확인했다.
- 공식 upstream 업데이트는 개인 수정을 덮어쓸 수 있다. 상단 다운로드 링크의 공식 패키지에는 이 수정이 없다.
