#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "run under sudo" >&2
  exit 2
fi

# 8.8.8.8, not 1.1.1.1: the carrier behind the phone hotspot blocks 1.1.1.1,
# which would fail the baseline before anything is tested.
target_ipv4=${DROIDBRIDGE_KILLSWITCH_TARGET:-8.8.8.8}
interface=$(/sbin/route -n get default | awk '$1 == "interface:" { print $2; exit }')
if [[ ! "$interface" =~ ^[A-Za-z0-9._-]{1,15}$ ]]; then
  echo "FAIL: could not resolve a safe default interface" >&2
  exit 1
fi
if [[ "$interface" == utun* ]]; then
  echo "FAIL: stop the DroidBridge tunnel first (default route is on $interface)" >&2
  exit 1
fi
if ! /sbin/ping -c 1 -t 2 "$target_ipv4" >/dev/null 2>&1; then
  echo "FAIL: baseline egress to $target_ipv4 is unavailable" >&2
  exit 1
fi
echo "baseline egress ok on $interface"

anchor="com.apple/io.droidbridge-check-$$"
pf_token=""
work=$(mktemp -d -t droidbridge-killswitch)
probe_pid=""
cleanup() {
  [[ -z "$probe_pid" ]] || kill "$probe_pid" >/dev/null 2>&1 || true
  /sbin/pfctl -a "$anchor" -F rules >/dev/null 2>&1 || true
  if [[ -n "$pf_token" ]]; then
    /sbin/pfctl -X "$pf_token" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# A connection opened on the physical interface BEFORE protection is the case a
# silent drop gets wrong: writes are accepted, nothing comes back, and the app
# hangs until a TCP timeout (seen live with the Claude app's API socket). The
# ruleset must reset it at once so the app reconnects through the tunnel.
mkfifo "$work/go"
python3 - "$target_ipv4" "$work/go" "$work/ready" "$work/result" <<'PY' &
import errno, socket, sys, time
target, go, ready, out = sys.argv[1:5]
try:
    s = socket.create_connection((target, 443), timeout=5)
except OSError as e:
    open(ready, "w").write(f"noconnect:{e}")
    sys.exit(0)
open(ready, "w").write("connected")
open(go).read()                      # released once pf is loaded
s.settimeout(6)
start = time.time()
try:
    s.sendall(b"\x16\x03\x01\x00\x05probe")
    verdict = "answered" if s.recv(1) else "closed"
except (ConnectionResetError, BrokenPipeError):
    verdict = "reset"
except socket.timeout:
    verdict = "hung"
except OSError as e:
    verdict = f"error:{errno.errorcode.get(e.errno, e.errno)}"
open(out, "w").write(f"{verdict} {time.time() - start:.2f}\n")
PY
probe_pid=$!
for _ in $(seq 1 60); do [[ -s "$work/ready" ]] && break; sleep 0.1; done
if [[ "$(cat "$work/ready" 2>/dev/null)" != "connected" ]]; then
  echo "FAIL: could not open the pre-protection connection: $(cat "$work/ready" 2>/dev/null)" >&2
  exit 1
fi
echo "pre-protection connection open on $interface"

# Use the helper's own PfRuleBuilder output so this check can never pass
# against a ruleset the helper would not actually load. Falls back to a
# literal copy only when no helper binary was supplied.
helper=${1:-}
if [[ -n "$helper" && -x "$helper" ]]; then
  rules=$("$helper" --selftest-pf-rules "utun-check" "$interface")
else
  echo "note: no helper binary given; using a literal ruleset copy" >&2
  rules=$(printf 'set block-policy return\nblock return out all\npass quick on lo0\nblock return out quick on %s all\n' "$interface")
fi
grep -q '^block return out all$' <<<"$rules" || {
  echo "FAIL: ruleset does not deny egress by default with an immediate error" >&2
  exit 1
}
/sbin/pfctl -a "$anchor" -f - <<<"$rules"

# Read back what the kernel actually holds: a rule that parsed but was not
# installed would otherwise look like protection.
loaded=$(/sbin/pfctl -a "$anchor" -s rules 2>/dev/null)
grep -q 'block return out all' <<<"$loaded" || {
  echo "FAIL: the default-deny rule is not present in the loaded anchor" >&2
  exit 1
}
echo "loaded ruleset denies egress by default"
enable_output=$(/sbin/pfctl -E 2>&1)
pf_token=$(sed -nE 's/^[[:space:]]*Token[[:space:]]*:[[:space:]]*([0-9]+).*$/\1/p' <<<"$enable_output" | head -1)
if [[ -z "$pf_token" ]]; then
  echo "FAIL: pfctl did not return an enable token" >&2
  exit 1
fi

echo go >"$work/go"
wait "$probe_pid" 2>/dev/null || true
probe_pid=""
# read exits 1 at EOF without a newline even though it filled the variables, so
# never let its status overwrite a verdict that was actually read.
verdict="none"; elapsed="?"
if [[ -s "$work/result" ]]; then read -r verdict elapsed <"$work/result" || true; fi
if [[ "$verdict" != "reset" ]] || ! awk "BEGIN{exit !($elapsed < 2)}"; then
  echo "FAIL: a pre-protection connection was '$verdict' after ${elapsed}s instead of reset at once" >&2
  exit 1
fi
echo "PASS: pre-protection connection was reset in ${elapsed}s (apps reconnect instead of hanging)"

if /sbin/ping -c 1 -t 2 "$target_ipv4" >/dev/null 2>&1; then
  echo "FAIL: traffic leaked through $interface" >&2
  exit 1
fi
echo "PASS: physical egress was blocked"

cleanup
trap - EXIT INT TERM
pf_token=""
if /sbin/ping -c 1 -t 2 "$target_ipv4" >/dev/null 2>&1; then
  echo "PASS: physical egress was restored"
else
  echo "FAIL: egress did not recover after cleanup" >&2
  exit 1
fi
