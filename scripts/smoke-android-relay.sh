#!/usr/bin/env bash
# Real-device relay smoke: pair, then check DBP health and an OPEN_TCP handshake over ADB loopback.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adb="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
py="${PYTHON:-python3}"
[ -x "$adb" ] || { echo "adb not found; set ADB=/path/to/adb" >&2; exit 1; }

secret_file="$(mktemp -t droidbridge-secret)"
cleanup() {
  # overwrite the secret before removing it, and drop the ADB forwards
  [ -f "$secret_file" ] && dd if=/dev/zero of="$secret_file" bs=1 count="$(wc -c <"$secret_file")" 2>/dev/null || true
  rm -f "$secret_file"
  "$adb" forward --remove tcp:27184 2>/dev/null || true
  "$adb" forward --remove tcp:27183 2>/dev/null || true
}
trap cleanup EXIT INT TERM

"$adb" forward tcp:27184 tcp:27184
"$adb" forward tcp:27183 tcp:27183

echo "== Pairing (confirm the 6-digit SAS matches the phone) =="
"$py" "$here/tools/pairing_probe.py" --host 127.0.0.1 --port 27184 --secret-out "$secret_file"
secret_hex="$(xxd -p -c 64 "$secret_file")"

echo "Press Start on the Android app, then press Enter here."
read -r _

echo "== Relay health =="
DROIDBRIDGE_TEST_SECRET="$secret_hex" "$py" "$here/tools/dbp_probe.py" health --host 127.0.0.1 --port 27183
echo "== OPEN_TCP example.com:443 (no application data) =="
DROIDBRIDGE_TEST_SECRET="$secret_hex" "$py" "$here/tools/dbp_probe.py" open --host 127.0.0.1 --port 27183 --destination example.com:443

echo "Smoke complete. With Wi-Fi enabled, confirm 'adb shell dumpsys connectivity' shows the relay network as CELLULAR."
