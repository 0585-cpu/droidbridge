#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "run under sudo" >&2
  exit 2
fi
if [[ $# -ne 1 || ! -x "$1" ]]; then
  echo "usage: sudo $0 /path/to/DroidBridgeHelper" >&2
  exit 2
fi

helper=$1
status_file=$(mktemp -t droidbridge-utun.XXXXXX)
error_file=$(mktemp -t droidbridge-utun-error.XXXXXX)
helper_pid=""
cleanup() {
  if [[ -n "$helper_pid" ]]; then kill "$helper_pid" >/dev/null 2>&1 || true; fi
  rm -f "$status_file" "$error_file"
}
trap cleanup EXIT INT TERM

"$helper" --selftest-utun >"$status_file" 2>"$error_file" &
helper_pid=$!
for _ in {1..50}; do
  [[ -s "$status_file" ]] && break
  kill -0 "$helper_pid" >/dev/null 2>&1 || {
    echo "FAIL: helper exited before opening utun" >&2
    sed -n '1,20p' "$error_file" >&2
    exit 1
  }
  sleep 0.1
done

interface=$(sed -n '1p' "$status_file")
if [[ ! "$interface" =~ ^utun[0-9]+$ ]]; then
  echo "FAIL: helper did not report a valid utun interface" >&2
  sed -n '1,20p' "$error_file" >&2
  exit 1
fi

interface_state=$(ifconfig "$interface" 2>/dev/null || true)
if grep -q "inet 198.18.0.2 --> 198.18.0.1" <<<"$interface_state" \
  && grep -q "mtu 1280" <<<"$interface_state"; then
  echo "PASS: opened and configured $interface"
else
  echo "FAIL: $interface does not have the expected address and MTU" >&2
  exit 1
fi
