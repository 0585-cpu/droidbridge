#!/usr/bin/env bash
# Interactive real-interface leak test. Captures headers only on the Mac Wi-Fi interface.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
target="${DROIDBRIDGE_FAULT_IPV4:-}"
port="${DROIDBRIDGE_FAULT_PORT:-443}"
adb="${ADB:-$(command -v adb || true)}"
[[ -n "$target" ]] || { echo "set DROIDBRIDGE_FAULT_IPV4 to an operator-controlled public IPv4" >&2; exit 2; }
[[ -n "$adb" && -x "$adb" ]] || { echo "adb not found" >&2; exit 2; }
[[ "${DROIDBRIDGE_WIFI_BASELINE_CONFIRMED:-0}" == "1" ]] || {
  echo "first confirm ordinary Wi-Fi egress, then set DROIDBRIDGE_WIFI_BASELINE_CONFIRMED=1" >&2; exit 2;
}
python3 - "$target" <<'PY'
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
if ip.version != 4 or not ip.is_global: raise SystemExit("fault target must be public IPv4")
PY
wifi="${DROIDBRIDGE_WIFI_INTERFACE:-$(networksetup -listallhardwareports | awk '/Wi-Fi/ && !found {getline; print $2; found=1}')}"
[[ "$wifi" =~ ^[A-Za-z0-9._-]{1,15}$ ]] || { echo "invalid Wi-Fi interface" >&2; exit 2; }
networksetup -getairportpower "$wifi" | grep -q 'On$' || { echo "Mac Wi-Fi must be on" >&2; exit 1; }
[[ "$(/sbin/route -n get "$target" | awk '$1=="interface:" && !found {print $2;found=1}')" == utun* ]] || {
  echo "start the DroidBridge tunnel before this test" >&2; exit 1;
}
sudo -n true 2>/dev/null || { echo "run 'sudo -v' first so tcpdump can start non-interactively" >&2; exit 2; }

case "${1:-all}" in
  all) scenarios=(usb relay cellular sleep) ;;
  usb|relay|cellular|sleep) scenarios=("$1") ;;
  *) echo "usage: $0 [all|usb|relay|cellular|sleep]" >&2; exit 2 ;;
esac

mkdir -p build/evidence
summary="$(mktemp -t droidbridge-killswitch-summary.XXXXXX)"
capture_pid="" request_pid=""
cleanup() {
  [[ -z "$request_pid" ]] || kill "$request_pid" >/dev/null 2>&1 || true
  [[ -z "$capture_pid" ]] || sudo kill "$capture_pid" >/dev/null 2>&1 || true
  rm -f "$summary"
}
trap cleanup EXIT INT TERM

pause_for() {
  if [[ "${DROIDBRIDGE_NONINTERACTIVE:-0}" != "1" ]]; then
    read -r -p "$1 Press Return immediately after the fault. " _
  fi
}

for scenario in "${scenarios[@]}"; do
  capture="build/evidence/killswitch-${scenario}-wifi.txt"
  attempts="$(mktemp -t droidbridge-killswitch-attempts.XXXXXX)"
  : >"$capture"; : >"$attempts"
  sudo tcpdump -ni "$wifi" -s 96 -tt -l "host $target and tcp" >"$capture" 2>/dev/null &
  capture_pid=$!
  (
    while true; do
      timestamp="$(python3 -c 'import time; print(time.time())')"
      if nc -G 1 -z "$target" "$port" >/dev/null 2>&1; then status=0; else status=1; fi
      printf '%s %s\n' "$timestamp" "$status" >>"$attempts"
      sleep 0.2
    done
  ) &
  request_pid=$!
  sleep 2

  case "$scenario" in
    usb) pause_for "Physically unplug the Android USB cable." ;;
    relay) "$adb" shell am force-stop io.droidbridge.android >/dev/null ;;
    cellular) "$adb" shell svc data disable >/dev/null ;;
    sleep) pause_for "Sleep the Mac for at least 15 seconds, then wake it." ;;
  esac
  marker="$(python3 -c 'import time; print(time.time())')"
  sleep "${DROIDBRIDGE_FAULT_OBSERVE_SECONDS:-8}"
  kill "$request_pid" >/dev/null 2>&1 || true; wait "$request_pid" 2>/dev/null || true; request_pid=""
  sudo kill "$capture_pid" >/dev/null 2>&1 || true; wait "$capture_pid" 2>/dev/null || true; capture_pid=""

  read -r leaked post_attempts successful_after first_failure_ms < <(
    python3 - "$capture" "$attempts" "$marker" "$target" <<'PY'
import sys
capture, attempts, marker, target = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
leaked = 0
for line in open(capture, errors="replace"):
    fields = line.split()
    try: timestamp = float(fields[0])
    except (IndexError, ValueError): continue
    if timestamp >= marker and target in line: leaked += 1
post = []
for line in open(attempts, errors="replace"):
    fields = line.split()
    if len(fields) == 2 and float(fields[0]) >= marker: post.append((float(fields[0]), int(fields[1])))
successes = sum(status == 0 for _, status in post)
failure = next((ts for ts, status in post if status != 0), None)
blocked_ms = -1 if failure is None else max(0, round((failure - marker) * 1000))
print(leaked, len(post), successes, blocked_ms)
PY
  )
  route_after="$(/sbin/route -n get "$target" | awk '$1=="interface:" && !found {print $2;found=1}')"
  passed=false
  if [[ "$leaked" == "0" && "$post_attempts" -gt 0 && "$successful_after" == "0" \
        && "$first_failure_ms" -ge 0 && "$first_failure_ms" -le 3000 && "$route_after" == utun* ]]; then
    passed=true
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$scenario" "$passed" "$leaked" \
    "$post_attempts" "$successful_after" "$first_failure_ms" "$route_after" >>"$summary"
  rm -f "$attempts"

  case "$scenario" in
    usb) pause_for "Reconnect USB, authorize ADB, then use Prepare Relay in DroidBridge." ;;
    relay) pause_for "Start the Android app and relay, then use Prepare Relay in DroidBridge." ;;
    cellular)
      "$adb" shell svc data enable >/dev/null || true
      pause_for "Wait for cellular service, start the relay, then use Prepare Relay in DroidBridge."
      ;;
    sleep) pause_for "Confirm the relay is prepared after wake." ;;
  esac
  nc -G 10 -z "$target" "$port" >/dev/null 2>&1 || {
    echo "recovery failed after $scenario" >&2
    exit 1
  }
done

python3 - "$summary" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
scenarios = {}
for line in open(sys.argv[1]):
    name, passed, leaked, attempts, successes, blocked, interface = line.rstrip().split("\t")
    scenarios[name] = {
        "passed": passed == "true", "leakedPackets": int(leaked),
        "postFaultAttempts": int(attempts), "successfulPostFaultAttempts": int(successes),
        "blockedWithinMs": int(blocked), "routeInterface": interface,
    }
data = {"test": "b1-killswitch", "passed": bool(scenarios) and all(x["passed"] for x in scenarios.values()),
        "scenarios": scenarios}
write_evidence(data, Path("build/evidence/killswitch.json"))
print("killswitch:", "PASS" if data["passed"] else "FAIL", "-> build/evidence/killswitch.json")
raise SystemExit(0 if data["passed"] else 1)
PY
