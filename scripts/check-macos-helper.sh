#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"
xcodegen generate >/dev/null
xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHelperChecks \
  -configuration Debug -derivedDataPath build/DerivedData-HelperChecks \
  CODE_SIGNING_ALLOWED=NO build >/dev/null
product="$repo/build/DerivedData-HelperChecks/Build/Products/Debug/DroidBridgeHelperChecks"
[[ -x "$product" ]] || { echo "missing helper-check executable" >&2; exit 1; }
"$product"
"$repo/scripts/check-helper-operation-lock.sh"
