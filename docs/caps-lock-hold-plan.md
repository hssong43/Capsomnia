# Caps Lock 한영 전환과 길게 눌러 ON/OFF

## 목표와 설계

Caps Lock을 짧게 누르면 한영만 전환하고 잠자기 방지 ON/OFF를 바꾸지 않는다. ON과 OFF 모두 실제 Caps Lock을 0.8초 이상 누른 입력으로 전환한다. 입력 이벤트를 소비하거나 재전송하지 않는다.

전원 요청 상태는 실제 SleepDisabled에서 초기화한다. 이후에는 길게 누르기 또는 메뉴·단축키·타이머·CLI의 명시적 요청으로만 갱신한다. 한영 전환 중 native Caps Lock이 ON/OFF로 흔들리거나 LED 쓰기 확인이 실패해도 전원 목표를 바꾸지 않는다. helper 성공과 실제 SleepDisabled 확인으로 전원 상태를 표시한다.

키를 뗀 뒤 LED output element(usage page 8, Caps Lock usage 2)에 확인된 실제 전원 상태를 쓰고 출력 결과를 확인한다. 드라이버 캐시가 같아도 최초/키 release/입력 소스 변화 후 명시적으로 갱신한다. modifier와 output은 분리하며 오래된 출력 완료가 새 갱신 필요 상태를 지우지 않게 한다. 실패하면 최대 초당 한 번 재시도한다. 오래된 LED 쓰기 완료는 새 전원 목표를 덮어쓰지 않는다. CLI/자동 OFF의 오래된 완료도 명령 revision으로 거부하여 새 요청을 보존한다. 실제 전원 확인에 실패하면 LED 값을 추측해서 쓰지 않는다. 앱의 정상 종료/신호 종료 때 LED와 잠자기 방지를 OFF로 복원한다.

키 길이는 실제 IOHID timestamp와 동일한 monotonic clock으로 잰다. 기존 250ms polling을 재사용하며 한 번 누른 동안 최대 1회 전환한다. wake, 키보드 분리 또는 명시적 명령 후 오래된 누름을 취소한다. 입력 모니터링 권한이 필요하다.

## 검증 순서

1. 짧은 OFF→native ON, 짧은 ON→native OFF, LED 쓰기 실패, native 흔들림, 양방향 0.8초/한 번만 실행, 중복 보고, 누락 release/명시적 취소, 지연 LED 완료, 보안 입력을 테스트로 재현한다.
2. RED 확인 후 구현하고 전체 Swift suite, release 빌드, 연결된 코드의 독립 검토를 수행한다.
3. 기존 앱/설정 백업과 helper/LaunchAgent를 유지하며 수정본을 교체한다. 권한·실제 전원과 LED 일치·짧은 한영/길게 ON/OFF를 사용자와 확인한다.
4. 같은 브랜치와 개인 fork PR #1을 최종 구현/검증 중심으로 갱신한다. 승인 없이 merge하지 않는다.

## 확인된 증거와 한계

- 첫 OFF만 보호한 버전은 실제 사용자 시험에서 짧은 ON/전환 실패/LED 불일치가 재현되어 완료로 간주하지 않는다.
- 새 양방향/LED 회귀 10개에서 RED assertion 21건을 확인했다. GREEN과 설치 결과는 실행 후 별도로 기록한다.
- 기존 helper의 실제 상태 확인, drift 재검증, CLI 명시적 OFF의 sleep 검증을 보존한다.
- Secure Event Input에서는 기존 modifier OFF 보호를 유지한다. LED output은 modifier를 바꾸지 않으므로 실제 전원 상태로 따로 표시한다. 실물 암호 입력 동작 검증은 별도로 구분한다.
- 실제 키보드·한영 입력·wake·덮개 검증은 단위 테스트로 증명하지 못하며 확인 여부를 구분한다. 공식 업데이트로 개인 수정이 덮어써질 수 있다.

- 최종 자동 검증: `swift test` 203개, 실물 하드웨어 테스트 2개 skipped, 실패 0. 설치/사용자 실물 확인은 아직 대기.

- 독립 검토의 helper 실패 시 LED 기준/오래된 CLI·자동 OFF 완료 경합 2건은 추가 회귀 RED(7개 assertion 실패) 후 GREEN으로 해결했다.

- MacBook Pro 내장 키보드의 LED output 직접 OFF 시험은 사용자가 실제 꺼짐을 확인했다. 새 출력 경로 적용 후 전체 단/장 입력과 불빛은 재확인한다.

- 직접 LED 강제 출력 실패가 캐시 일치로 숨지 않도록 current-generation 오류를 UI/doctor에 유지하는 회귀를 RED→GREEN으로 검증했다.
