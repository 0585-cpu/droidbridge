#!/usr/bin/env bash
# Generate the Xcode project and run the shared package checks. Requires XcodeGen 2.46.0 and Xcode.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v xcodegen >/dev/null; then
  echo "xcodegen not found. Install: brew install xcodegen (need 2.46.0)" >&2; exit 1
fi
version="$(xcodegen --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
[ "$version" = "2.46.0" ] || echo "warning: xcodegen $version (expected 2.46.0)" >&2

( cd "$here" && xcodegen generate )
# Under Command Line Tools the checks run as an executable; under Xcode, swift test also works.
swift run --package-path "$here/macos/Shared" Checks
