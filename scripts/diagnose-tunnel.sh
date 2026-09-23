#!/usr/bin/env bash
# Read-only snapshot of a RUNNING DroidBridge tunnel. Changes no state: it only
# observes, so it is safe to run while the tunnel is up and egress is blocked.
# Writes everything to build/diagnostics/tunnel-<timestamp>.txt for later review.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$here"

adb="${ADB:-$HOME/Library/Android/sdk/platform-tools/adb}"
out_dir="build/diagnostics"
mkdir -p "$out_dir"
out="$out_dir/tunnel-$(date +%Y%m%d-%H%M%S).txt"
exec > >(tee "$out") 2>&1

say() { echo; echo "===== $* ====="; }

# A snapshot of a stopped tunnel cannot answer anything, so refuse early and
# say exactly what is missing rather than producing a misleading report.
route_if="$(route -n get default 2>/dev/null | awk '$1=="interface:"{print $2}')"
if [[ "${route_if:-}" != utun* ]]; then
  echo "the tunnel is NOT running: the default route is on '${route_if:-none}', not a utun." >&2
  echo "Start it in the menu-bar app (Prepare Relay -> Start Tunnel), then re-run this." >&2
  exit 2
fi

say "when"
date
echo "uid=$(id -u)  (run under sudo for pf rule inspection)"

say "tunnel interface + route"
ifconfig -l | tr ' ' '\n' | grep '^utun' | tr '\n' ' '; echo
utun="$(route -n get default 2>/dev/null | awk '$1=="interface:"{print $2}')"
echo "default route interface: ${utun:-none}"
route -n get default 2>/dev/null | sed -n '1,12p'
if [[ "${utun:-}" == utun* ]]; then ifconfig "$utun" 2>/dev/null; fi

say "DNS: is the system resolver inside the tunnel?"
# Browsers use the system resolver; earlier probes used IP literals or an
# explicit @198.18.0.1 and so never exercised this path.
echo "resolver #1 nameserver: $(scutil --dns | awk '/^resolver #1/{f=1} f&&/nameserver\[0\]/{print $3; exit}')"
networksetup -listnetworkserviceorder 2>/dev/null | awk '/^\([0-9]+\) /{sub(/^\([0-9]+\) /,""); print}' |
  while IFS= read -r svc; do
    printf '  %-24s -> %s\n' "$svc" "$(networksetup -getdnsservers "$svc" 2>&1 | tr '\n' ' ')"
  done
echo "--- recovery journal (no secrets: gateway, utun, pf token, DNS originals) ---"
cat /Library/PrivilegedHelperTools/io.droidbridge.recovery.json 2>&1; echo
echo "--- hostnames through the SYSTEM resolver ---"
for url in https://example.com/ https://www.apple.com/ https://api.anthropic.com/ https://claude.ai/; do
  r=$(curl -s -m 12 -o /dev/null -w "http=%{http_code} dns=%{time_namelookup}s connect=%{time_connect}s total=%{time_total}s" "$url"); rc=$?
  echo "  $url -> $r rc=$rc   (6 = no DNS, 28 = timeout)"
done
echo "--- same names straight at the tunnel resolver (isolates DNS from TCP) ---"
for name in example.com api.anthropic.com claude.ai; do
  echo "  $name -> $(dig +short +time=4 +tries=1 "$name" @198.18.0.1 A 2>&1 | tr '\n' ' ')"
done

say "pf: is our anchor loaded?"
if sudo -n true 2>/dev/null || [[ "$(id -u)" == "0" ]]; then
  echo "--- anchor rules ---"
  pfctl -a com.apple/io.droidbridge -s rules 2>&1
  echo "--- pf enabled? ---"
  pfctl -s info 2>&1 | head -4
else
  echo "(no root: skipping pf inspection)"
fi

say "relay plumbing"
"$adb" forward --list 2>&1
echo "--- listener ---"
netstat -an -p tcp 2>/dev/null | grep 27183

say "helper daemon"
launchctl print system/io.droidbridge.helper 2>&1 | grep -E "state =|pid =|last exit" | head -4
ls -la /Library/PrivilegedHelperTools/io.droidbridge.recovery.json 2>&1 | head -1

# --- the actual experiment -------------------------------------------------
say "BASELINE counters"
netstat -ib 2>/dev/null | awk -v i="${utun:-none}" 'NR==1 || $1==i' | head -3

say "EXPERIMENT 1: DNS through the virtual resolver (known-good path)"
time dig +time=4 +tries=1 example.com @198.18.0.1 2>&1 | grep -E "ANSWER|status:|^example|connection timed out" | head -5

say "EXPERIMENT 2: TCP to a fixed IPv4 (no DNS involved)"
# Sample relay connections WHILE the TCP attempt runs: if the engine opens a
# flow, a non-LISTEN socket to 127.0.0.1:27183 appears here.
# The target must be reachable FROM THE PHONE, and the window must outlast the
# relay's 10s connect timeout — otherwise a carrier-blocked address (1.1.1.1 is
# blocked on this carrier) or a too short deadline looks like a broken data plane.
tcp_target="${DROIDBRIDGE_TCP_TARGET:-8.8.8.8}"
echo "target: $tcp_target (override with DROIDBRIDGE_TCP_TARGET)"
( curl -s --max-time 20 -o /dev/null -w "curl: HTTP %{http_code} connect=%{time_connect}s total=%{time_total}s\n" "https://$tcp_target/" 2>&1 & )
for i in $(seq 1 11); do
  sleep 2
  n=$(netstat -an -p tcp 2>/dev/null | grep 27183 | grep -vc LISTEN)
  echo "t+$((i * 2))s relay flows=$n"
  netstat -an -p tcp 2>/dev/null | grep 27183 | grep -v LISTEN | head -3
done
wait 2>/dev/null

say "AFTER counters (Opkts rising = packets reached utun; Ipkts = engine wrote back)"
netstat -ib 2>/dev/null | awk -v i="${utun:-none}" 'NR==1 || $1==i' | head -3

say "EXPERIMENT 3: does the phone see the flow?"
"$adb" logcat -d -t 400 2>/dev/null \
  | grep -iE "droidbridge|OPEN_TCP|OPEN_OK|OPEN_ERROR|POLICY_DENIED|DBP|relay|flow" \
  | grep -viE "InsetsController|VRI\[|HWUI|InputMethod|ImeTracker|InsetsSource" \
  | tail -30

say "helper log"
log show --last 5m --predicate 'process == "io.droidbridge.helper"' 2>/dev/null \
  | grep -viE "^Filtering|^Timestamp" | tail -20

say "done"
echo "saved to: $out"
