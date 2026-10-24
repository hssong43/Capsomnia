#!/bin/zsh
set -u
contents="$(cd "$(dirname "$0")/.." && pwd)"
binary="$contents/MacOS/Capsomnia"
export CAPSOMNIA_SUPERVISED=1

restore_mapping() {
  "$binary" --restore-native-caps-lock --owner-pid "$child_pid"
}
stop_child() {
  trap '' TERM INT HUP
  /bin/kill -TERM "$child_pid" 2>/dev/null || true
  wait "$child_pid" 2>/dev/null || true
  restore_mapping || exit 1
  exit 0
}

"$binary" "$@" &
child_pid=$!
trap stop_child TERM INT HUP
wait "$child_pid"
child_result=$?
restore_mapping || exit 1
exit "$child_result"
