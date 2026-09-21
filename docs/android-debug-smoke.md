# Android relay debug smoke

Proves the Android relay is reachable over ADB loopback and binds outbound traffic to cellular,
before any macOS code exists. Real device with active mobile data required.

## Prerequisites

- One Android phone (API 26+) connected over USB with debugging authorized.
- `adb` on PATH or `ADB=/path/to/adb`.
- `pip install -r tools/requirements-dev.txt` (the pairing probe needs `cryptography`).

## Steps

```bash
./scripts/install-android-debug.sh      # build + install + launch
# On the phone: tap "Pair New Mac"
./scripts/smoke-android-relay.sh        # pair, then health + OPEN_TCP over loopback
```

Expected:

```text
ADB device: authorized
Pairing SAS: 6 digits and identical on both screens
Relay health: cellular=available protocol=DBP/1
OPEN_TCP example.com:443: OPEN_OK
```

## Notes

- The relay listener binds `127.0.0.1:27183`; pairing binds `127.0.0.1:27184`. Only ADB forwarding
  exposes them to the Mac.
- Turn Wi-Fi on during the test; `adb shell dumpsys connectivity` should still show the relay's
  selected network as `TRANSPORT_CELLULAR`. This test does not assert exact CGNAT addresses.
- The probe holds the Pairing Secret only in a wiped temp file (mode 0600); the smoke script
  overwrites and deletes it on exit.
