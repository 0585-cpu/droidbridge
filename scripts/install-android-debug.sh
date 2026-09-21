#!/usr/bin/env bash
# Build and install the DroidBridge debug APK to the single attached device, then open the app.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adb="${ADB:-$(command -v adb || echo "$HOME/Library/Android/sdk/platform-tools/adb")}"
[ -x "$adb" ] || { echo "adb not found; set ADB=/path/to/adb" >&2; exit 1; }

count="$("$adb" devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
[ "$count" = "1" ] || { echo "expected exactly one authorized device, found $count" >&2; "$adb" devices >&2; exit 1; }
echo "ADB device: authorized"

( cd "$here/android" && ./gradlew installDebug )
"$adb" shell am start -n io.droidbridge.android/io.droidbridge.MainActivity
echo "Installed and launched. Press Start on the phone before running smoke-android-relay.sh."
