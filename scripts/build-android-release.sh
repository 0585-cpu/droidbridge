#!/usr/bin/env bash
# Local developer Android build: run unit tests + lint, then assemble a signed
# APK. Uses release signing from ~/.gradle (outside the repo) if configured,
# else the debug key for local-only testing. No keystore is copied into build/.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here/android"

# JDK17: honor JAVA_HOME if set, else the Gradle-provisioned Adoptium 17.
if [ -z "${JAVA_HOME:-}" ]; then
  cand="$HOME/.gradle/jdks/eclipse_adoptium-17-aarch64-os_x.2/jdk-17.0.20.1+1/Contents/Home"
  [ -d "$cand" ] && export JAVA_HOME="$cand"
fi

./gradlew testDebugUnitTest lintDebug

if ./gradlew tasks --all 2>/dev/null | grep -qx "assembleRelease" \
   && [ -n "${DROIDBRIDGE_ANDROID_KEYSTORE:-}" ]; then
  ./gradlew assembleRelease
  apk="$(ls -t app/build/outputs/apk/release/*.apk 2>/dev/null | head -1)"
else
  echo "no release keystore configured -> building debug APK for local testing"
  ./gradlew assembleDebug
  apk="$(ls -t app/build/outputs/apk/debug/*.apk 2>/dev/null | head -1)"
fi

[ -n "${apk:-}" ] && [ -f "$apk" ] || { echo "APK not found" >&2; exit 1; }
echo "android build: PASS  ($apk)"
