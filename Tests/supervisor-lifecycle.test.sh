#!/bin/zsh
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
task_tmp="$(mktemp -d)"
cleanup() {
  if [[ -f "$task_tmp/child.pid" ]]; then /bin/kill -TERM "$(cat "$task_tmp/child.pid")" 2>/dev/null || true; fi
  /bin/rm -rf "$task_tmp"
}
trap cleanup EXIT
/bin/mkdir -p "$task_tmp/Contents/Resources" "$task_tmp/Contents/MacOS"
/bin/cp "$root/scripts/run-capsomnia.sh" "$task_tmp/Contents/Resources/run-capsomnia.sh"
cat > "$task_tmp/Contents/MacOS/Capsomnia" <<'APP'
#!/bin/zsh
if [[ "${1:-}" == "--restore-native-caps-lock" ]]; then
  [[ "${2:-}" == "--owner-pid" && "${3:-}" == "$(cat "$CAPS_TEST_CHILD")" ]] || exit 7
  if [[ "${CAPS_TEST_FAIL_RESTORE:-0}" == 1 ]]; then exit 5; fi
  /bin/rm -f "$CAPS_TEST_MAPPING"
  exit 0
fi
[[ "${CAPSOMNIA_SUPERVISED:-0}" == 1 ]] || exit 8
print -r -- $$ > "$CAPS_TEST_CHILD"
/usr/bin/touch "$CAPS_TEST_MAPPING"
case "${CAPS_TEST_MODE:-normal}" in
  normal) exit 0 ;;
  crash) /bin/kill -KILL $$ ;;
  linger) trap 'exit 0' TERM; while true; do /bin/sleep 0.1; done ;;
esac
APP
/bin/chmod 0755 "$task_tmp/Contents/MacOS/Capsomnia"
export CAPS_TEST_MAPPING="$task_tmp/mapping"
export CAPS_TEST_CHILD="$task_tmp/child.pid"
for mode in normal crash; do
  export CAPS_TEST_MODE="$mode"
  set +e
  /bin/zsh "$task_tmp/Contents/Resources/run-capsomnia.sh"
  result=$?
  set -e
  if [[ -e "$CAPS_TEST_MAPPING" ]]; then print -u2 "FAILED: $mode must restore key mapping"; exit 1; fi
  if [[ "$mode" == normal && "$result" != 0 ]]; then exit 1; fi
  if [[ "$mode" == crash && "$result" == 0 ]]; then exit 1; fi
  print "PASS: $mode cleanup"
done
export CAPS_TEST_MODE=linger
/bin/zsh "$task_tmp/Contents/Resources/run-capsomnia.sh" &
supervisor=$!
for i in {1..100}; do [[ -e "$CAPS_TEST_MAPPING" ]] && break; /bin/sleep 0.02; done
/bin/kill -TERM "$supervisor"
wait "$supervisor"
[[ ! -e "$CAPS_TEST_MAPPING" ]] || { print -u2 'FAILED: TERM must restore'; exit 1; }
print 'PASS: TERM cleanup'
export CAPS_TEST_MODE=normal CAPS_TEST_FAIL_RESTORE=1
set +e
/bin/zsh "$task_tmp/Contents/Resources/run-capsomnia.sh"
result=$?
set -e
[[ "$result" != 0 ]] || { print -u2 'FAILED: restore failure must propagate'; exit 1; }
print 'PASS: restore failure propagates'
