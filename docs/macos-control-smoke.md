# macOS control-plane smoke

Verifies the Mac host app path: detect the Android device, pair over ADB loopback, and read
authenticated relay health showing cellular available. The Packet Tunnel is **not** started here.

## Requirements

- Apple Silicon, macOS 14+, full **Xcode** (not just Command Line Tools).
- XcodeGen 2.46.0 (`brew install xcodegen`).
- A signing team: `export DROIDBRIDGE_DEVELOPMENT_TEAM=<team id>`.
- One authorized Android device with the debug app installed (`./scripts/install-android-debug.sh`).

## Run

```bash
./scripts/run-macos-control-smoke.sh --preflight   # environment only
./scripts/run-macos-control-smoke.sh               # build, sign, and guide the manual smoke
```

Expected end state: the menu bar shows `Relay ready; full tunnel not installed`, the carrier name,
and cellular available.

## Status without Xcode

The shared logic (`macos/Shared`) is verified today with an assert-based `Checks` executable
(`swift run --package-path macos/Shared Checks`) because Command Line Tools ship no XCTest. The
SwiftUI app, signing, and this device smoke require full Xcode; do not declare the control plane
release-complete until they pass.
