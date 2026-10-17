#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$repo/build/usb-checks"
clang -std=c11 -Wall -Wextra \
  -I "$repo/macos/USB/Sources/CAoaUSB/include" \
  -I "$repo/macos/USB/Sources/CAoaUSB/vendor" \
  "$repo/macos/USB/Tests/CAoaUSBWriteChecks.c" \
  -o "$repo/build/usb-checks/write-deadline"
"$repo/build/usb-checks/write-deadline"
