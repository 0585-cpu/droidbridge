# DroidBridge

Use an Android phone's LTE/5G as a fail-closed IPv4 TCP/DNS tunnel exit for a Mac over USB
(Android Open Accessory / AOA). Android root and macOS kernel extensions are not required. The app does not alter TTL,
APN, DUN, or carrier settings and does not claim to change how a carrier bills or classifies traffic.

Status: **AOA transport implemented; real-device acceptance pending** (IPv4 TCP + DNS).
The [AOA plan](docs/superpowers/plans/2026-09-23-droidbridge-aoa-plan.md) replaces the product
ADB transport. USB debugging and a host ADB installation are no longer required for use.
The [next development plan](docs/superpowers/plans/2026-09-23-droidbridge-udp-traffic-profile-plan.md)
adds general UDP/QUIC, optional socket TTL and traffic controls, then IPv6 and recovery improvements.
Those features are not implemented by this transport change.

## Layout

```text
macos/      HostApp + signed privileged utun helper + dormant Packet Tunnel target
core/       C17 DBP/1 codec, destination policy, packet engine (later: lwIP)
protocol/   DBP/1 wire spec and canonical test vectors (Python generator)
tools/      check_environment, vector generator, dbp_probe, mock_relay
android/    Cellular-bound relay app (Kotlin)
docs/       specs, plans, threat model, operations
```

## Requirements

- macOS 14+, Apple Silicon
- cmake ≥ 3.28, clang (Xcode CLT), Python ≥ 3.11
- App builds: Xcode, XcodeGen, Android SDK, JDK 17
- Android API 26+ device with USB accessory support, a USB data cable
- libusb 1.0.30 is built from a verified source archive and bundled; Homebrew is not a runtime requirement.

## Build and test

```bash
make test-core          # configure + build + ctest
make verify-foundation  # + environment check, protocol vector check, Python tests
make fuzz-smoke         # 10s libFuzzer run per parser target (needs `brew install llvm` on macOS)
make check-macos        # shared protocol/state checks
make check-macos-usb    # USB codec, handshake, and actual loopback multiplex tests
make test-android      # unit tests, lint, debug APK
DROIDBRIDGE_DEVELOPMENT_TEAM=YOUR_TEAM ./scripts/build-signed-macos.sh
```

The signed menu-bar app provides device selection, authenticated P-256/SAS pairing, relay health,
administrator-authorized helper installation, and Start/Stop Tunnel controls. The helper owns utun,
the default route, and the pf kill switch; startup orders protection before the route change and
teardown restores the route before removing protection. Authenticated health checks block the data
plane on relay/cellular loss and retry with 1/2/4-second backoff. The menu also provides an
administrator-authorized helper removal action that refuses to remove retained fail-closed state.

AOA setup and pending hardware checks are documented in
[`docs/aoa-device-acceptance.md`](docs/aoa-device-acceptance.md). The earlier
[`B1 benchmark guide`](docs/b1-device-acceptance.md) contains legacy ADB commands;
those commands are development tools, not the new app connection flow.

Regenerate fixtures after editing `tools/generate_protocol_vectors.py` (the
canonical source for all wire encodings):

```bash
python3 tools/generate_protocol_vectors.py
```

## Probe a relay

`tools/mock_relay.py` stands in for the Android relay; `tools/dbp_probe.py`
checks wire compatibility against any relay. The secret is read only from
`DROIDBRIDGE_TEST_SECRET` (64 hex chars) and is never printed.

```bash
export DROIDBRIDGE_TEST_SECRET=0000000000000000000000000000000000000000000000000000000000000001
python3 tools/mock_relay.py --port 27183 &
python3 tools/dbp_probe.py health --host 127.0.0.1 --port 27183
python3 tools/dbp_probe.py open --host 127.0.0.1 --port 27183 --destination example.com:443
python3 tools/dbp_probe.py dns --host 127.0.0.1 --port 27183 --name example.com --type A
```

CI (`.github/workflows/foundation.yml`) runs the same gate on macOS 15 and
Ubuntu 24.04 with ASan/UBSan.

## License

BSD-3-Clause. See `LICENSE`. Security issues: see `SECURITY.md`.
