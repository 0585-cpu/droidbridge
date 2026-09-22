#!/usr/bin/env bash
set -euo pipefail

if [[ "$(id -u)" != "0" ]]; then
  echo "run under sudo" >&2
  exit 2
fi

target_ipv4=${DROIDBRIDGE_KILLSWITCH_TARGET:-1.1.1.1}
interface=$(/sbin/route -n get default | awk '$1 == "interface:" { print $2; exit }')
if [[ ! "$interface" =~ ^[A-Za-z0-9._-]{1,15}$ ]]; then
  echo "FAIL: could not resolve a safe default interface" >&2
  exit 1
fi
if ! /sbin/ping -c 1 -t 2 "$target_ipv4" >/dev/null 2>&1; then
  echo "FAIL: baseline egress to $target_ipv4 is unavailable" >&2
  exit 1
fi
echo "baseline egress ok on $interface"

anchor="com.apple/io.droidbridge-check-$$"
pf_token=""
cleanup() {
  /sbin/pfctl -a "$anchor" -F rules >/dev/null 2>&1 || true
  if [[ -n "$pf_token" ]]; then
    /sbin/pfctl -X "$pf_token" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

# Use the helper's own PfRuleBuilder output so this check can never pass
# against a ruleset the helper would not actually load. Falls back to a
# literal copy only when no helper binary was supplied.
helper=${1:-}
if [[ -n "$helper" && -x "$helper" ]]; then
  rules=$("$helper" --selftest-pf-rules "utun-check" "$interface")
else
  echo "note: no helper binary given; using a literal ruleset copy" >&2
  rules=$(printf 'set block-policy drop\nblock drop out all\npass quick on lo0\nblock drop out quick on %s all\n' "$interface")
fi
grep -q '^block drop out all$' <<<"$rules" || {
  echo "FAIL: ruleset does not deny egress by default" >&2
  exit 1
}
/sbin/pfctl -a "$anchor" -f - <<<"$rules"

# Read back what the kernel actually holds: a rule that parsed but was not
# installed would otherwise look like protection.
loaded=$(/sbin/pfctl -a "$anchor" -s rules 2>/dev/null)
grep -q 'block drop out all' <<<"$loaded" || {
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
