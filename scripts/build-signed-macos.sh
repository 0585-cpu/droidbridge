#!/usr/bin/env bash
# Signed macOS build. Injects the signing team at build time (never stored in
# the repo) and verifies the shipped entitlements on HostApp + extension.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

team="${DROIDBRIDGE_DEVELOPMENT_TEAM:-}"
[ -n "$team" ] || { echo "DROIDBRIDGE_DEVELOPMENT_TEAM is required (10-char Team ID)" >&2; exit 2; }

dd="$here/build/DerivedData"
xcodegen generate
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost -configuration Release \
  -derivedDataPath "$dd" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic build

app="$dd/Build/Products/Release/DroidBridge.app"
ext="$app/Contents/PlugIns/DroidBridgePacketTunnel.appex"
[ -d "$app" ] || { echo "missing built app at $app" >&2; exit 1; }
[ -d "$ext" ] || { echo "missing built extension at $ext" >&2; exit 1; }

check_ent() { # bundle  needle  label
  codesign -d --entitlements :- "$1" 2>/dev/null | grep -q "$2" \
    && echo "[PASS] $3" || { echo "[FAIL] $3" >&2; return 1; }
}
rc=0
check_ent "$app" "group.io.droidbridge.shared" "host app-group" || rc=1
check_ent "$ext" "group.io.droidbridge.shared" "ext app-group" || rc=1
check_ent "$ext" "packet-tunnel-provider" "ext packet-tunnel entitlement" || rc=1
check_ent "$app" "io.droidbridge.shared" "host keychain-access-group" || rc=1
check_ent "$ext" "io.droidbridge.shared" "ext keychain-access-group" || rc=1

echo "signed build: $([ $rc = 0 ] && echo PASS || echo FAIL)  ($app)"
exit $rc
