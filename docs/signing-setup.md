# DroidBridge macOS Signing Setup (B1)

The Packet Tunnel extension needs the `com.apple.developer.networking.networkextension`
(`packet-tunnel-provider`) entitlement. macOS will **only load** a Network System
Extension signed by a team that owns that capability.

## Requirements

- **Paid Apple Developer Program** membership. A free Apple ID can create an
  "Apple Development" certificate but **cannot** provision the packet-tunnel
  entitlement — the extension will fail to start on device.
- Xcode signed in with that Apple ID (Xcode ▸ Settings ▸ Accounts).

## One-time steps

1. **Sign in** Xcode ▸ Settings ▸ Accounts ▸ add your Apple ID. Confirm the team
   row shows your paid program (not "Personal Team").
2. **Verify a certificate exists** — after sign-in:
   ```bash
   security find-identity -v -p codesigning | grep "Apple Development"
   ```
   If empty, in Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ `+` ▸
   "Apple Development".
3. **Find your Team ID** (10 chars) at <https://developer.apple.com/account> ▸
   Membership, or `Manage Certificates`. Export it:
   ```bash
   export DROIDBRIDGE_DEVELOPMENT_TEAM=ABCDE12345
   ```
   Add it to your shell profile so scripts pick it up.
4. **App IDs / App Group** — with automatic signing, Xcode registers
   `io.droidbridge.macos`, `io.droidbridge.macos.PacketTunnel`, the App Group
   `group.io.droidbridge.shared`, and the keychain group on first signed build.
   If automatic registration is blocked, create them once in the developer
   portal with the Network Extensions and App Groups capabilities enabled.

## Build

```bash
./scripts/build-signed-macos.sh    # needs DROIDBRIDGE_DEVELOPMENT_TEAM
```

It runs XcodeGen, builds Release into `build/DerivedData`, and asserts the
shipped entitlements on both the app and the `.appex`.

## Notes

- The Team ID is injected at build time via `DEVELOPMENT_TEAM=...`; it is **not**
  committed to `project.yml`, so the repo stays team-agnostic.
- `.xcodeproj` is gitignored — regenerate with `xcodegen generate`.
- Signing certificates and private keys never leave the login keychain; no
  signing material is written into `build/`.
