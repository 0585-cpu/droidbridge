#!/usr/bin/env bash
# Signed helper-mode macOS build. The dormant NetworkExtension target is kept
# buildable unsigned, but is intentionally not embedded for a free-team release.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

team="${DROIDBRIDGE_DEVELOPMENT_TEAM:-}"
[ -n "$team" ] || { echo "DROIDBRIDGE_DEVELOPMENT_TEAM is required (10-char Team ID)" >&2; exit 2; }

dd="$here/build/DerivedData"
dd_ne="$here/build/DerivedData-NE"
xcodegen generate
make check-macos-helper

# Keep the dormant paid-account path compiling without asking the free team to
# provision the NetworkExtension entitlement.
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgePacketTunnel \
  -configuration Debug -derivedDataPath "$dd_ne" CODE_SIGNING_ALLOWED=NO build

xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost -configuration Release \
  -derivedDataPath "$dd" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_STYLE=Automatic build

app="$dd/Build/Products/Release/DroidBridge.app"
helper="$app/Contents/Library/LaunchDaemons/DroidBridgeHelper"
daemon_plist="$app/Contents/Library/LaunchDaemons/io.droidbridge.helper.plist"
[ -d "$app" ] || { echo "missing built app at $app" >&2; exit 1; }
[ -x "$helper" ] || { echo "missing embedded helper at $helper" >&2; exit 1; }
[ -f "$daemon_plist" ] || { echo "missing embedded launchd plist at $daemon_plist" >&2; exit 1; }

check_ent() { # bundle  needle  label
  codesign -d --entitlements :- "$1" 2>/dev/null | grep -q "$2" \
    && echo "[PASS] $3" || { echo "[FAIL] $3" >&2; return 1; }
}
rc=0
codesign --verify --deep --strict "$app" >/dev/null 2>&1 \
  && echo "[PASS] app signature verifies" || { echo "[FAIL] app signature" >&2; rc=1; }
check_ent "$app" "group.io.droidbridge.shared" "host app-group" || rc=1
check_ent "$app" "io.droidbridge.shared" "host keychain-access-group" || rc=1
host_runtime_team="$(plutil -extract DroidBridgeTeamIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
[ "$host_runtime_team" = "$team" ] \
  && echo "[PASS] host runtime signing team" || { echo "[FAIL] host runtime signing team" >&2; rc=1; }

helper_details="$(codesign -dvv "$helper" 2>&1)"
has() { grep -qF "$2" <<<"$1"; }
has "$helper_details" "Identifier=io.droidbridge.helper" \
  && echo "[PASS] helper identifier" || { echo "[FAIL] helper identifier" >&2; rc=1; }
has "$helper_details" "TeamIdentifier=$team" \
  && echo "[PASS] helper signed by team" || { echo "[FAIL] helper signing team" >&2; rc=1; }
codesign --verify --strict "$helper" >/dev/null 2>&1 \
  && echo "[PASS] helper signature verifies" || { echo "[FAIL] helper signature" >&2; rc=1; }
helper_runtime_team="$("$helper" --selftest-signing-team 2>/dev/null || true)"
[ "$helper_runtime_team" = "$team" ] \
  && echo "[PASS] helper runtime signing team" || { echo "[FAIL] helper runtime signing team" >&2; rc=1; }
helper_entitlements="$(codesign -d --entitlements :- "$helper" 2>&1 || true)"
if has "$helper_entitlements" "networkextension"; then
  echo "[FAIL] helper must not carry a NetworkExtension entitlement" >&2
  rc=1
else
  echo "[PASS] helper has no NetworkExtension entitlement"
fi
plutil -lint "$daemon_plist" >/dev/null \
  && echo "[PASS] launchd plist" || { echo "[FAIL] launchd plist" >&2; rc=1; }
if [ ! -d "$app/Contents/PlugIns/DroidBridgePacketTunnel.appex" ]; then
  echo "[PASS] dormant NetworkExtension excluded from free-team app"
else
  echo "[FAIL] free-team app unexpectedly embeds NetworkExtension" >&2
  rc=1
fi

echo "signed helper-mode build: $([ "$rc" -eq 0 ] && echo PASS || echo FAIL)  ($app)"
exit $rc
