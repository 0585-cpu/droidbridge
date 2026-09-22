#!/usr/bin/env bash
# Real-relay negative tests plus first-party source policy checks. The real
# pairing secret is accepted only through the process environment and is never
# printed or written to evidence.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
private_ip="${DROIDBRIDGE_PRIVATE_PROBE_IPV4:-10.255.255.1}"
private_port="${DROIDBRIDGE_PRIVATE_PROBE_PORT:-80}"
test_secret="${DROIDBRIDGE_TEST_SECRET:-}"

[[ "$test_secret" =~ ^[0-9A-Fa-f]{64}$ ]] || {
  echo "DROIDBRIDGE_TEST_SECRET must be the real 64-character pairing secret" >&2
  exit 2
}

python3 - "$private_ip" "$private_port" <<'PY'
import ipaddress, sys
value = ipaddress.ip_address(sys.argv[1])
if value.version != 4 or not value.is_private:
    raise SystemExit("private probe must be a private IPv4 address")
port = int(sys.argv[2])
if not 1 <= port <= 65535:
    raise SystemExit("private probe port must be between 1 and 65535")
PY

listener=false private_blocked=false unauthenticated_rejected=false
rootless_android=false logging_scan=false forbidden_scan=false

if lsof -nP -iTCP@127.0.0.1:27183 -sTCP:LISTEN >/dev/null 2>&1; then
  listener=true
fi

set +e
policy_output="$(DROIDBRIDGE_TEST_SECRET="$test_secret" python3 tools/dbp_probe.py open \
  --host 127.0.0.1 --port 27183 --destination "$private_ip:$private_port" 2>&1)"
policy_status=$?
set -e
if [[ "$listener" == true && "$policy_status" -eq 2 \
      && "$policy_output" == *"status=error"* \
      && "$policy_output" == *"error=POLICY_DENIED"* ]]; then
  private_blocked=true
fi
unset policy_output test_secret

bad_key="$(openssl rand -hex 32)"
set +e
auth_output="$(DROIDBRIDGE_TEST_SECRET="$bad_key" \
  python3 tools/dbp_probe.py health --host 127.0.0.1 --port 27183 2>&1)"
auth_status=$?
set -e
if [[ "$listener" == true && "$auth_status" -eq 3 \
      && "$auth_output" == *"status=auth_failed"* ]]; then
  unauthenticated_rejected=true
fi
unset auth_output bad_key

if ! rg -n 'su\b|Runtime\.getRuntime\(\)\.exec\([^)]*su|android:sharedUserId="android\.uid\.system"' \
    android/app/src/main >/dev/null; then
  rootless_android=true
fi

if ! rg -n '(Log\.|println|NSLog|os_log|logger).*(secret|payload|destination|cookie|authorization)' \
    android/app/src/main macos/Helper macos/HostApp macos/CoreHost core/src core/ports >/dev/null; then
  logging_scan=true
fi

if ! rg -n 'startTethering|TetheringManager|TYPE_MOBILE_DUN|tether_dun_required|WRITE_APN_SETTINGS|APN_TYPE_DUN|setsockopt[^\n]*IP_TTL' \
    android/app/src/main macos/Helper macos/HostApp macos/CoreHost core/src core/ports >/dev/null; then
  forbidden_scan=true
fi

python3 - "$listener" "$private_blocked" "$unauthenticated_rejected" "$rootless_android" \
  "$logging_scan" "$forbidden_scan" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
names = ["relayListener", "privateDestinationBlocked", "unauthenticatedRejected",
         "androidRootless", "loggingScan", "forbiddenApiScan"]
checks = {name: value == "true" for name, value in zip(names, sys.argv[1:7])}
data = {
    "test": "b1-security",
    "passed": all(checks.values()),
    "checks": checks,
}
write_evidence(data, Path("build/evidence/security.json"))
print("security:", "PASS" if data["passed"] else "FAIL", "-> build/evidence/security.json")
raise SystemExit(0 if data["passed"] else 1)
PY
