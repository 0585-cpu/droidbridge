#!/usr/bin/env bash
set -euo pipefail

test_directory="$(mktemp -d -t droidbridge-operation-lock.XXXXXX)"
lock_file="$test_directory/operation.lock"
continued_marker="$test_directory/continued"
worker_pid=""
cleanup() {
  [[ -z "$worker_pid" ]] || kill "$worker_pid" >/dev/null 2>&1 || true
  rm -f "$lock_file" "$continued_marker"
  rmdir "$test_directory" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

/bin/sh -c "
  /usr/bin/shlock -f \"\$1\" -p \$\$ || exit 73
  trap 'trap - 1 2 15; exit 74' 1 2 15
  trap '/bin/rm -f \"\$1\"' 0
  counter=0
  while test \"\$counter\" -lt 40; do
    /bin/sleep 0.05
    counter=\$((counter + 1))
  done
  /usr/bin/touch \"\$2\"
" droidbridge-operation-lock-check "$lock_file" "$continued_marker" &
worker_pid=$!

for _ in {1..100}; do
  [[ -f "$lock_file" ]] && break
  sleep 0.01
done
[[ -f "$lock_file" ]] || { echo "operation lock was not created" >&2; exit 1; }

kill -TERM "$worker_pid"
set +e
wait "$worker_pid"
worker_status=$?
set -e
worker_pid=""

[[ "$worker_status" -eq 74 ]] || {
  echo "signal handler did not terminate the privileged operation" >&2
  exit 1
}
[[ ! -e "$lock_file" ]] || { echo "operation lock was not released" >&2; exit 1; }
[[ ! -e "$continued_marker" ]] || { echo "operation continued after signal" >&2; exit 1; }

/usr/bin/shlock -f "$lock_file" -p $$
rm -f "$lock_file"
echo "helper operation lock: signal termination passed"
