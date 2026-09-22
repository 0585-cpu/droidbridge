#!/usr/bin/env bash
# One-GiB integrity gate plus mixed one-hour tunnel soak and memory sampling.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
: "${DROIDBRIDGE_BENCH_HOST:?set DROIDBRIDGE_BENCH_HOST to your public benchmark server}"
: "${DROIDBRIDGE_BENCH_PORT:?set DROIDBRIDGE_BENCH_PORT}"
duration="60m"
if [[ $# -gt 0 ]]; then
  [[ "$1" == "--duration" && $# -eq 2 ]] || { echo "usage: $0 [--duration 60m]" >&2; exit 2; }
  duration="$2"
fi
duration_seconds="$(python3 - "$duration" <<'PY'
import sys
from tools.b1_benchmark import parse_duration
print(parse_duration(sys.argv[1]))
PY
)"

python3 - "$DROIDBRIDGE_BENCH_HOST" <<'PY'
import ipaddress, sys
try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    pass
else:
    raise SystemExit("B1 soak requires a DNS hostname, not a numeric IP address")
PY

resolved="$(python3 - "$DROIDBRIDGE_BENCH_HOST" <<'PY'
import ipaddress, socket, sys
for item in socket.getaddrinfo(sys.argv[1], None, socket.AF_INET, socket.SOCK_STREAM):
    ip = ipaddress.ip_address(item[4][0])
    if ip.is_global: print(ip); break
else: raise SystemExit("benchmark host has no public IPv4")
PY
)"
[[ "$(/sbin/route -n get "$resolved" | awk '$1=="interface:" && !found {print $2;found=1}')" == utun* ]] || {
  echo "benchmark traffic is not routed through DroidBridge" >&2; exit 1;
}

mkdir -p build/evidence
integrity="$(python3 tools/b1_benchmark.py download --host "$DROIDBRIDGE_BENCH_HOST" \
  --port "$DROIDBRIDGE_BENCH_PORT" --bytes 1073741824)"
memory_file="build/evidence/soak-memory.tsv"
: >"$memory_file"
result_file="$(mktemp -t droidbridge-soak-result.XXXXXX)"
soak_pid=""
cleanup() {
  [[ -z "$soak_pid" ]] || kill "$soak_pid" >/dev/null 2>&1 || true
  rm -f "$result_file"
}
trap cleanup EXIT INT TERM

python3 tools/b1_benchmark.py soak --host "$DROIDBRIDGE_BENCH_HOST" \
  --port "$DROIDBRIDGE_BENCH_PORT" --duration "$duration" >"$result_file" &
soak_pid=$!
while kill -0 "$soak_pid" >/dev/null 2>&1; do
  epoch="$(date +%s)"
  app_kb="$(ps -axo rss=,comm= | awk '$2 ~ /\/DroidBridge$/ {sum+=$1} END{print sum+0}')"
  helper_kb="$(ps -axo rss=,comm= | awk '$2 ~ /\/DroidBridgeHelper$/ {sum+=$1} END{print sum+0}')"
  android_kb="$(${ADB:-adb} shell dumpsys meminfo io.droidbridge.android 2>/dev/null | tr -d '\r' |
    awk '/TOTAL PSS:/ && !found {value=$3; found=1} /^ *TOTAL +[0-9]/ && !found {value=$2; found=1} END{print found ? value : 0}')"
  relay_connections="$(lsof -nP -iTCP:27183 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1{n++} END{print n+0}')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$epoch" "$app_kb" "$helper_kb" "$android_kb" "$relay_connections" >>"$memory_file"
  sleep 60
done
wait "$soak_pid"; soak_pid=""
soak_result="$(cat "$result_file")"
sleep 15
remaining="$(lsof -nP -iTCP:27183 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1{n++} END{print n+0}')"

python3 - "$integrity" "$soak_result" "$memory_file" "$duration_seconds" "$remaining" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
integrity = json.loads(sys.argv[1]); soak = json.loads(sys.argv[2]); expected = int(sys.argv[4])
samples = []
for line in open(sys.argv[3]):
    epoch, app, helper, android, flows = map(int, line.rstrip().split("\t"))
    samples.append((epoch, app, helper, android, flows))
def growth(index):
    if not samples: return 10**9
    cutoff = samples[0][0] + min(600, expected // 2)
    values = [row[index] for row in samples if row[0] >= cutoff and row[index] > 0]
    return max(values) - min(values) if values else 10**9
growths = {"appRssGrowthKiB": growth(1), "helperRssGrowthKiB": growth(2),
           "androidPssGrowthKiB": growth(3)}
memory_ok = all(value <= 50 * 1024 for value in growths.values())
remaining = int(sys.argv[5])
gate = (expected >= 3600 and integrity.get("bytes") == 1073741824 and integrity.get("integrityVerified")
        and soak.get("passed") and soak.get("failures") == 0 and soak.get("dnsChecks", 0) > 0
        and soak.get("tcpConnectionCycles", 0) > 0 and memory_ok and remaining == 0)
data = {
    "test": "b1-soak", "passed": bool(gate), "integrityTransfer": integrity,
    "workload": soak, "memory": {**growths, "samples": len(samples), "passed": memory_ok},
    "dnsHostnameVerified": True,
    "remainingRelayConnections": remaining, "requiredDurationSeconds": 3600,
}
write_evidence(data, Path("build/evidence/soak.json"))
print("soak:", "PASS" if gate else "FAIL", "-> build/evidence/soak.json")
raise SystemExit(0 if gate else 1)
PY
