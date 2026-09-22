# B1 USB device acceptance

These checks require an Apple Silicon Mac, one authorized Android device with mobile data, the
signed DroidBridge app/helper, and public test endpoints you control. They intentionally do not
change TTL, APN, DUN, carrier settings, SIP, or AMFI.

## Benchmark endpoint

On a public host protected by a firewall that permits only the test phone/Mac source ranges, run:

```bash
python3 tools/b1_benchmark.py server --bind 0.0.0.0 --port 28443
```

The DBB1 server transfers deterministic bytes and records nothing. It is plain TCP, so expose only
the dedicated test port and remove the firewall rule after acceptance.

## Authenticated policy probe

Before pairing the Mac app, use a dedicated, temporary probe pairing. Tap **Pair New Mac** on the
Android device, run the command below, confirm the six-digit SAS, and then start the Android relay
when prompted:

```bash
./scripts/smoke-android-relay.sh
```

The script holds the probe secret only in a protected temporary file and process environment,
requires an authenticated DBP request to a private IPv4 destination to return `POLICY_DENIED`,
checks that a random invalid key is rejected, and removes the temporary secret and ADB forwards on
exit. It records no pairing material. Because Android retains only the current peer, pair the Mac
app again after this probe.

## App workflow

1. Install/start the Android app and connect USB with USB debugging authorized.
2. Launch the signed `DroidBridge.app`.
3. Choose the device if prompted. Tap **Pair New Mac** on both sides and approve only when the
   six-digit codes match.
4. Start the Android relay, choose **Prepare Relay**, then **Start Tunnel**. Approve the macOS
   administrator prompt used to install the signed LaunchDaemon helper.
5. Use **Stop Tunnel** before quitting or uninstalling. A teardown failure deliberately leaves the
   kill switch active and displays an error.
6. To remove the root component, choose **Remove Privileged Helper…** and approve the administrator
   prompt. Removal first requests the helper's explicit Stop transition and refuses to unregister
   or delete files while fail-closed recovery state remains.

## Evidence commands

First run the signed/device preflight. The helper check is expected to fail until the app has been
started once and the administrator install has completed.

```bash
export DROIDBRIDGE_DEVELOPMENT_TEAM=YOUR_TEAM_ID
./scripts/b1-preflight.sh
```

Set the operator-controlled functional endpoints and direct Android cellular baseline, turn Mac
Wi-Fi/Ethernet off, and run:

```bash
DROIDBRIDGE_IP_PROBE_URL=https://your-host/ip-json \
DROIDBRIDGE_ANDROID_BASELINE_IPV4=YOUR_PHONE_PUBLIC_IPV4 \
DROIDBRIDGE_ANDROID_BASELINE_ASN=YOUR_CARRIER_ASN \
DROIDBRIDGE_TEST_HOST=your-https-host \
DROIDBRIDGE_TEST_IPV4=YOUR_HTTPS_PUBLIC_IPV4 \
DROIDBRIDGE_GIT_URL=https://your-host/test.git \
DROIDBRIDGE_SSH_HOST=your-ssh-host \
./scripts/b1-functional.sh
```

Then configure the benchmark endpoint:

```bash
export DROIDBRIDGE_BENCH_HOST=your-public-benchmark-host
export DROIDBRIDGE_BENCH_PORT=28443
./scripts/b1-stress.sh
./scripts/b1-performance.sh
./scripts/b1-soak.sh --duration 60m
```

For the real-interface leak test, first demonstrate ordinary Wi-Fi egress before starting the
tunnel, start DroidBridge with Mac Wi-Fi still on, cache sudo authorization, and run all four
operator-guided faults:

```bash
sudo -v
DROIDBRIDGE_WIFI_BASELINE_CONFIRMED=1 \
DROIDBRIDGE_FAULT_IPV4=YOUR_OPERATOR_PUBLIC_IPV4 \
DROIDBRIDGE_FAULT_PORT=443 \
./scripts/b1-killswitch.sh all
```

Each fault must block within three seconds without packets on the Mac Wi-Fi interface, retain the
utun default route, and then successfully pass a fresh TCP check after USB/relay/cellular/sleep
recovery. These four successful post-fault checks are the reconnect evidence; ordinary TCP
connections in the one-hour workload do not count as reconnects.

Finally, combine the redacted results into the 14-criterion release manifest:

```bash
make b1-acceptance
```

Only `build/evidence/acceptance.json` with `"passed": true` satisfies the B1 device gate.

Outputs are written below `build/evidence/`. The scripts store only aggregate state, interface,
latency, byte-count, and memory facts; they do not store transferred content, URLs, DNS query names,
pairing material, cookies, or authorization headers.

Do not create the `v0.1.0-b1` tag until all device evidence is green. Passing desktop/unit builds
alone is not a device acceptance result.
