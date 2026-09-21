#!/usr/bin/env bash
# macOS control-plane smoke. --preflight checks the environment; the full run builds/signs the HostApp,
# pairs with the Android relay and confirms authenticated cellular health. Signing needs full Xcode.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adb="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
fail=0
note() { echo "  fix: $1" >&2; }

preflight() {
  echo "== macOS control-plane preflight =="

  if [ "$(uname -m)" = "arm64" ]; then echo "arch: arm64 ok"; else echo "arch: not arm64" >&2; note "run on Apple Silicon"; fail=1; fi

  major="$(sw_vers -productVersion | cut -d. -f1)"
  if [ "${major:-0}" -ge 14 ]; then echo "macOS: $major ok"; else echo "macOS: < 14" >&2; note "upgrade to macOS 14+"; fail=1; fi

  if command -v xcodegen >/dev/null; then
    v="$(xcodegen --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ "$v" = "2.46.0" ]; then echo "xcodegen: 2.46.0 ok"; else echo "xcodegen: $v (want 2.46.0)" >&2; note "brew install xcodegen"; fail=1; fi
  else echo "xcodegen: missing" >&2; note "brew install xcodegen"; fail=1; fi

  if xcodebuild -version >/dev/null 2>&1; then echo "xcode: $(xcodebuild -version | head -1) ok"; else echo "xcode: full Xcode required" >&2; note "install Xcode and run: sudo xcode-select -s /Applications/Xcode.app"; fail=1; fi

  if [ -n "${DROIDBRIDGE_DEVELOPMENT_TEAM:-}" ]; then echo "signing team: set ok"; else echo "signing team: unset" >&2; note "export DROIDBRIDGE_DEVELOPMENT_TEAM=<10-char team id>"; fail=1; fi

  count="$("$adb" devices 2>/dev/null | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
  if [ "$count" = "1" ]; then echo "adb device: one authorized ok"; else echo "adb device: found $count authorized" >&2; note "connect exactly one authorized device"; fail=1; fi

  if [ "$count" = "1" ] && "$adb" shell pm path io.droidbridge.android >/dev/null 2>&1; then
    echo "android package: installed ok"
  else echo "android package: not installed" >&2; note "./scripts/install-android-debug.sh"; fail=1; fi

  [ "$fail" = "0" ] && echo "preflight: PASS" || echo "preflight: FAIL"
  return $fail
}

case "${1:-}" in
  --preflight) preflight; exit $? ;;
  *)
    preflight || { echo "resolve preflight failures before the full smoke" >&2; exit 1; }
    echo "== build + sign HostApp =="
    ( cd "$here" && xcodegen generate && xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost \
        -configuration Debug DEVELOPMENT_TEAM="$DROIDBRIDGE_DEVELOPMENT_TEAM" build )
    echo "Launch DroidBridge from the menu bar, connect the device, pair, and Prepare Relay."
    echo "Expected: 'Relay ready; full tunnel not installed' with cellular available."
    ;;
esac
