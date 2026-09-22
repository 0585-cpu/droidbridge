#!/usr/bin/env bash
# Real-device functional acceptance. The operator controls every endpoint and radio-state change.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
adb="${ADB:-$(command -v adb || true)}"

require() { [[ -n "${!1:-}" ]] || { echo "missing required environment variable: $1" >&2; exit 2; }; }
for name in DROIDBRIDGE_IP_PROBE_URL DROIDBRIDGE_ANDROID_BASELINE_IPV4 \
  DROIDBRIDGE_ANDROID_BASELINE_ASN DROIDBRIDGE_TEST_HOST DROIDBRIDGE_TEST_IPV4 \
  DROIDBRIDGE_GIT_URL DROIDBRIDGE_SSH_HOST; do require "$name"; done
[[ -n "$adb" && -x "$adb" ]] || { echo "adb not found" >&2; exit 2; }
[[ "$DROIDBRIDGE_IP_PROBE_URL" == https://* && "$DROIDBRIDGE_IP_PROBE_URL" != *".example"* ]] || {
  echo "IP probe must be a real operator-approved HTTPS endpoint" >&2; exit 2;
}
[[ "$DROIDBRIDGE_GIT_URL" == https://* && "$DROIDBRIDGE_GIT_URL" != *".example"* ]] || {
  echo "Git endpoint must be a real HTTPS endpoint" >&2; exit 2;
}

python3 - "$DROIDBRIDGE_ANDROID_BASELINE_IPV4" "$DROIDBRIDGE_TEST_IPV4" <<'PY'
import ipaddress, sys
for raw in sys.argv[1:]:
    value = ipaddress.ip_address(raw)
    if value.version != 4 or not value.is_global:
        raise SystemExit(f"not a public IPv4 address: {raw}")
PY

pause_for() {
  if [[ "${DROIDBRIDGE_NONINTERACTIVE:-0}" != "1" ]]; then
    read -r -p "$1 Press Return to continue. " _
  fi
}

probe_exit() {
  curl --http1.1 --fail --silent --show-error --max-time 15 "$DROIDBRIDGE_IP_PROBE_URL" |
    python3 -c '
import ipaddress, json, sys
raw = sys.stdin.buffer.read(65537)
if len(raw) > 65536: raise SystemExit("probe response too large")
obj = json.loads(raw)
ip = ipaddress.ip_address(obj.get("ip", ""))
if ip.version != 4 or not ip.is_global: raise SystemExit("probe did not return public IPv4")
asn = str(obj.get("asn", "")).strip().upper()
print(f"{ip}\t{asn}")
'
}

route_interface="$(/sbin/route -n get "$DROIDBRIDGE_TEST_IPV4" | awk '$1 == "interface:" && !found {print $2; found=1}')"
[[ "$route_interface" == utun* ]] || {
  echo "the test destination is not routed through utun; start DroidBridge first" >&2; exit 1;
}
wifi_device="$(networksetup -listallhardwareports | awk '/Wi-Fi/ && !found {getline; print $2; found=1}')"
wifi_power="$(networksetup -getairportpower "$wifi_device" 2>/dev/null || true)"
[[ "$wifi_power" == *Off ]] || {
  echo "turn Mac Wi-Fi off for the initial isolation test" >&2; exit 1;
}
while read -r ethernet_device; do
  [[ -z "$ethernet_device" ]] && continue
  ethernet_state="$(ifconfig "$ethernet_device" 2>/dev/null || true)"
  if grep -q 'status: active' <<<"$ethernet_state"; then
    echo "disconnect or disable active Mac Ethernet interface $ethernet_device" >&2
    exit 1
  fi
done < <(networksetup -listallhardwareports | awk '/Hardware Port: .*Ethernet/{getline; print $2}')

dns_ok=false https_ok=false git_ok=false ssh_ok=false exit_ok=false wifi_on_ok=false cellular_off_ok=false recovery_ok=false
dns_result="$(dscacheutil -q host -a name "$DROIDBRIDGE_TEST_HOST" 2>/dev/null || true)"
if grep -q '^ip_address:' <<<"$dns_result"; then dns_ok=true; fi
if curl --http1.1 --fail --silent --show-error --output /dev/null --max-time 20 \
    "https://$DROIDBRIDGE_TEST_HOST/"; then https_ok=true; fi
if git -c http.version=HTTP/1.1 ls-remote "$DROIDBRIDGE_GIT_URL" HEAD >/dev/null 2>&1; then git_ok=true; fi
if nc -G 10 -z "$DROIDBRIDGE_SSH_HOST" "${DROIDBRIDGE_SSH_PORT:-22}" >/dev/null 2>&1; then ssh_ok=true; fi

IFS=$'\t' read -r initial_ip initial_asn < <(probe_exit)
if [[ -n "$initial_asn" && "$initial_asn" == "${DROIDBRIDGE_ANDROID_BASELINE_ASN^^}" ]]; then exit_ok=true; fi

pause_for "Enable Android Wi-Fi while leaving mobile data enabled."
wifi_state="$($adb shell settings get global wifi_on 2>/dev/null | tr -d '\r')"
IFS=$'\t' read -r wifi_ip wifi_asn < <(probe_exit)
if [[ "$wifi_state" == "1" && -n "$wifi_asn" && "$wifi_asn" == "${DROIDBRIDGE_ANDROID_BASELINE_ASN^^}" ]]; then
  wifi_on_ok=true
fi

pause_for "Disable Android mobile data but keep Android Wi-Fi enabled."
mobile_state="$($adb shell settings get global mobile_data 2>/dev/null | tr -d '\r')"
if [[ "$mobile_state" == "0" ]] && ! curl --http1.1 --fail --silent --output /dev/null --max-time 8 \
    "https://$DROIDBRIDGE_TEST_HOST/"; then
  cellular_off_ok=true
fi

pause_for "Restore mobile data, start the Android relay, and use Prepare Relay in DroidBridge."
if curl --http1.1 --fail --silent --show-error --output /dev/null --max-time 20 \
    "https://$DROIDBRIDGE_TEST_HOST/"; then recovery_ok=true; fi

python3 - "$dns_ok" "$https_ok" "$git_ok" "$ssh_ok" "$exit_ok" "$wifi_on_ok" \
  "$cellular_off_ok" "$recovery_ok" "$route_interface" "$initial_ip" "$initial_asn" "$wifi_ip" "$wifi_asn" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
names = ["dns", "https", "gitHttps", "sshTcp", "cellularExit", "androidWifiOnCellularExit",
         "cellularOffFailsClosed", "recovery"]
checks = {name: value == "true" for name, value in zip(names, sys.argv[1:9])}
data = {
    "test": "b1-functional",
    "passed": all(checks.values()),
    "checks": checks,
    "routeInterface": sys.argv[9],
    "macPhysicalIsolation": True,
    "initialExitIpv4": sys.argv[10],
    "initialExitAsn": sys.argv[11],
    "wifiOnExitIpv4": sys.argv[12],
    "wifiOnExitAsn": sys.argv[13],
}
write_evidence(data, Path("build/evidence/functional.json"))
print("functional:", "PASS" if data["passed"] else "FAIL", "-> build/evidence/functional.json")
raise SystemExit(0 if data["passed"] else 1)
PY
