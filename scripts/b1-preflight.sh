#!/usr/bin/env bash
# B1 signed-build + device preflight. Fails unless every acceptance precondition
# holds. Writes a redacted result to build/evidence/preflight.json.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

adb="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
checks=()   # "name|pass|detail"  detail must stay non-sensitive
fail=0

# check NAME  CMD... -> records pass/fail from exit status, no stdout captured
record() { local name="$1" ok="$2" detail="${3:-}"; checks+=("$name|$ok|$detail"); [ "$ok" = "true" ] || fail=1; }
yn() { [ "$1" -eq 0 ] && echo true || echo false; }
# has HAYSTACK PATTERN: grep a captured string. Never pipe a large producer into
# `grep -q` under `pipefail`: grep quits on first match, SIGPIPEs the producer,
# and the pipeline then reports 141, not grep's success.
has() { grep -qE "$2" <<<"$1"; }

# 1. arm64
[ "$(uname -m)" = "arm64" ]; record arch_arm64 "$(yn $?)"

# 2. macOS >= 14
osmajor="$(sw_vers -productVersion | cut -d. -f1)"
[ "${osmajor:-0}" -ge 14 ]; record macos_ge_14 "$(yn $?)" "major=$osmajor"

# 3. toolchain
xcodebuild -version >/dev/null 2>&1; record xcodebuild "$(yn $?)"
xg="$(xcodegen --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$xg" = "2.46.0" ]; record xcodegen_2_46_0 "$(yn $?)" "version=${xg:-none}"
cm="$(cmake --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"
awk "BEGIN{exit !(${cm:-0} >= 3.28)}"; record cmake_ge_3_28 "$(yn $?)" "version=${cm:-none}"
py="$(python3 -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)"
awk "BEGIN{exit !(${py:-0} >= 3.11)}"; record python_ge_3_11 "$(yn $?)" "version=${py:-none}"

# 4. signing team present
[ -n "${DROIDBRIDGE_DEVELOPMENT_TEAM:-}" ]; record team_env_set "$(yn $?)"
has "$(security find-identity -v -p codesigning 2>/dev/null)" "Apple Development"
record development_identity "$(yn $?)"

# 5. exactly one authorized adb device
if [ -x "$adb" ]; then
  count="$("$adb" devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
  [ "$count" = "1" ]; record one_authorized_device "$(yn $?)" "count=$count"
else
  record one_authorized_device false "adb_missing"; count=0
fi

# 6. Android API >= 26 and 7. package installed and 8. cellular network visible
if [ "${count:-0}" = "1" ]; then
  api="$("$adb" shell getprop ro.build.version.sdk 2>/dev/null | tr -d '\r')"
  [ "${api:-0}" -ge 26 ]; record android_api_ge_26 "$(yn $?)" "sdk=$api"
  has "$("$adb" shell pm list packages 2>/dev/null | tr -d '\r')" "^package:io\.droidbridge\.android$"
  record app_installed "$(yn $?)"
  # mobile data on + a cellular transport present
  has "$("$adb" shell settings get global mobile_data 2>/dev/null | tr -d '\r')" "^1$"
  record mobile_data_on "$(yn $?)"
  # A live cellular NetworkAgent shows "Transports: CELLULAR" in its nc{} block.
  has "$("$adb" shell dumpsys connectivity 2>/dev/null)" "Transports: CELLULAR"
  record cellular_network_visible "$(yn $?)"
else
  record android_api_ge_26 false; record app_installed false
  record mobile_data_on false; record cellular_network_visible false
fi

# 9. Mac Wi-Fi interface identified
wifi="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{getline; print $2; exit}')"
[ -n "$wifi" ]; record wifi_interface "$(yn $?)" "iface=${wifi:-none}"

# 10. no listener on 27183/27184 before setup
! lsof -nP -iTCP:27183 -sTCP:LISTEN >/dev/null 2>&1 && ! lsof -nP -iTCP:27184 -sTCP:LISTEN >/dev/null 2>&1
record relay_ports_free "$(yn $?)"

# 11. clean working tree
[ -z "$(git status --porcelain)" ]; record clean_tree "$(yn $?)"

# 12. all unit tests pass (foundation + Swift + core)
make verify-foundation >/dev/null 2>&1; record foundation_tests "$(yn $?)"
make check-macos >/dev/null 2>&1; record swift_checks "$(yn $?)"
make test-core >/dev/null 2>&1; record core_tests "$(yn $?)"

# --- emit evidence + human summary ---
python3 - "$fail" "${checks[@]}" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, "tools")
from evidence import write_evidence
fail = sys.argv[1]
items = {}
for raw in sys.argv[2:]:
    name, ok, detail = raw.split("|", 2)
    items[name] = {"passed": ok == "true", "detail": detail}
    print(f"[{'PASS' if ok=='true' else 'FAIL'}] {name}" + (f"  ({detail})" if detail else ""))
write_evidence({"test": "b1-preflight", "passed": fail == "0", "checks": items},
               Path("build/evidence/preflight.json"))
print("\npreflight:", "PASS" if fail == "0" else "FAIL",
      "-> build/evidence/preflight.json")
PY
exit $fail
