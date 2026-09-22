#!/usr/bin/env bash
# Compare direct Android cellular RTT with Mac-over-DroidBridge RTT and throughput.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
: "${DROIDBRIDGE_BENCH_HOST:?set DROIDBRIDGE_BENCH_HOST to your public benchmark server}"
: "${DROIDBRIDGE_BENCH_PORT:?set DROIDBRIDGE_BENCH_PORT}"
adb="${ADB:-$(command -v adb || true)}"
[[ -n "$adb" && -x "$adb" ]] || { echo "adb not found" >&2; exit 2; }

if [[ "${DROIDBRIDGE_SKIP_ANDROID_TEST_BUILD:-0}" != "1" ]]; then
  benchmark_jdk="${JAVA_HOME:-}"
  if [[ -z "$benchmark_jdk" ]]; then
    benchmark_jdk="$(find "$HOME/.gradle/jdks" -type d -path '*/Contents/Home' -print -quit 2>/dev/null || true)"
  fi
  if [[ -z "$benchmark_jdk" ]]; then
    benchmark_jdk="$(/usr/libexec/java_home -v 17 2>/dev/null || true)"
  fi
  [[ -x "$benchmark_jdk/bin/java" ]] || { echo "JDK 17 not found" >&2; exit 2; }
  (cd android && JAVA_HOME="$benchmark_jdk" ./gradlew assembleDebug assembleDebugAndroidTest >/dev/null)
  "$adb" install -r android/app/build/outputs/apk/debug/app-debug.apk >/dev/null
  "$adb" install -r android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk >/dev/null
fi

instrumentation="$($adb shell am instrument -w -r \
  -e class io.droidbridge.benchmark.CellularBenchmarkInstrumentedTest \
  -e host "$DROIDBRIDGE_BENCH_HOST" -e port "$DROIDBRIDGE_BENCH_PORT" \
  io.droidbridge.android.test/androidx.test.runner.AndroidJUnitRunner)"
baseline="$(python3 - "$instrumentation" <<'PY'
import json, re, sys
matches = re.findall(r'(?:droidbridgeBenchmark=|DROIDBRIDGE_BENCHMARK )({[^\r\n]+})', sys.argv[1])
if not matches: raise SystemExit("Android instrumentation did not emit benchmark metrics")
value = json.loads(matches[-1])
if value.get("cellularBound") is not True: raise SystemExit("baseline was not cellular-bound")
print(json.dumps(value, separators=(",", ":")))
PY
)"

if [[ "${DROIDBRIDGE_NONINTERACTIVE:-0}" != "1" ]]; then
  read -r -p "Android baseline is complete. Start the Android relay, Prepare Relay, and Start Tunnel; then press Return. " _
fi
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
mac="$(python3 tools/b1_benchmark.py performance --host "$DROIDBRIDGE_BENCH_HOST" \
  --port "$DROIDBRIDGE_BENCH_PORT" --bytes "${DROIDBRIDGE_PERFORMANCE_BYTES:-536870912}")"

python3 - "$baseline" "$mac" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
android = json.loads(sys.argv[1]); mac = json.loads(sys.argv[2])
added = round(mac["medianRttMs"] - android["medianRttMs"], 3)
gate = mac["throughputMbps"] >= 20 and added <= 40 and mac["integrityVerified"]
data = {
    "test": "b1-performance", "passed": gate,
    "androidCellular": android,
    "macTunnel": mac,
    "addedMedianRttMs": added,
    "releaseThresholds": {"minimumMbps": 20, "maximumAddedRttMs": 40},
    "targetsMet": mac["throughputMbps"] >= 50 and added <= 15,
}
write_evidence(data, Path("build/evidence/performance.json"))
print("performance:", "PASS" if gate else "FAIL", "-> build/evidence/performance.json")
raise SystemExit(0 if gate else 1)
PY
