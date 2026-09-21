#!/usr/bin/env bash
# Data-plane preflight. Runs the CLT-buildable C gate always; Swift/Xcode steps run only when available.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"
fail=0
step() { echo "== $1 =="; }

step "foundation + protocol"
make verify-foundation || fail=1

step "C data plane (build + tests)"
make test-core || fail=1

step "fuzz smoke"
make fuzz-smoke || fail=1

if command -v swift >/dev/null; then
  step "macOS Shared checks"
  make check-macos || fail=1
fi

if command -v xcodegen >/dev/null && xcodebuild -version >/dev/null 2>&1; then
  step "unsigned HostApp build"
  xcodegen generate && xcodebuild -project DroidBridge.xcodeproj -scheme DroidBridgeHost \
    -configuration Debug CODE_SIGNING_ALLOWED=NO build || fail=1
else
  echo "== skipping xcodegen/xcodebuild (full Xcode not installed) =="
fi

[ "$fail" = "0" ] && echo "data-plane preflight: PASS" || echo "data-plane preflight: FAIL"
exit $fail
