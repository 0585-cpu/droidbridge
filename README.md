# DroidBridge

Use an Android phone's LTE/5G as a fail-closed full-tunnel exit for a Mac over
USB (ADB TCP forwarding). No root, no kernel extension, no carrier tethering
tricks.

Status: **B1 in development** (IPv4 TCP + DNS). See
`docs/superpowers/plans/2026-09-21-droidbridge-b1-b3-roadmap.md`.

## Layout

```text
core/       C17 DBP/1 codec, destination policy, packet engine (later: lwIP)
protocol/   DBP/1 wire spec and canonical test vectors (Python generator)
tools/      check_environment, vector generator, dbp_probe, mock_relay
macos/      HostApp + PacketTunnel (Swift, later phase)
android/    Relay app (Kotlin, later phase)
docs/       specs, plans, threat model, operations
```

## Requirements

- macOS 14+, Apple Silicon
- cmake ≥ 3.28, clang (Xcode CLT), Python ≥ 3.11
- Later phases: Xcode, XcodeGen, Android Studio / SDK platform-tools, JDK

## Build and test

```bash
make test-core          # configure + build + ctest
make verify-foundation  # + environment check + protocol vector check
```

## License

BSD-3-Clause. See `LICENSE`. Security issues: see `SECURITY.md`.
