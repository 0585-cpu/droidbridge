#!/usr/bin/env bash
# 128-flow real-tunnel concurrency gate against tools/b1_benchmark.py server mode.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
: "${DROIDBRIDGE_BENCH_HOST:?set DROIDBRIDGE_BENCH_HOST to your public benchmark server}"
: "${DROIDBRIDGE_BENCH_PORT:?set DROIDBRIDGE_BENCH_PORT}"
flows="${DROIDBRIDGE_STRESS_FLOWS:-128}"
[[ "$flows" =~ ^[0-9]+$ && "$flows" -eq 128 ]] || { echo "B1 acceptance requires exactly 128 flows" >&2; exit 2; }

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

result="$(python3 tools/b1_benchmark.py stress --host "$DROIDBRIDGE_BENCH_HOST" \
  --port "$DROIDBRIDGE_BENCH_PORT" --flows 128 --echo-bytes 4096 --hold-seconds 10)"
sleep 15
remaining="$(lsof -nP -iTCP@127.0.0.1:27183 -sTCP:ESTABLISHED 2>/dev/null | awk 'NR>1{n++} END{print n+0}')"

python3 - "$result" "$remaining" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
metrics = json.loads(sys.argv[1])
metrics["remainingRelayConnections"] = int(sys.argv[2])
metrics["cleanupPassed"] = metrics["remainingRelayConnections"] == 0
data = {"test": "b1-stress", "passed": bool(metrics.get("passed")) and metrics["cleanupPassed"],
        "metrics": metrics}
write_evidence(data, Path("build/evidence/stress.json"))
print("stress:", "PASS" if data["passed"] else "FAIL", "-> build/evidence/stress.json")
raise SystemExit(0 if data["passed"] else 1)
PY
