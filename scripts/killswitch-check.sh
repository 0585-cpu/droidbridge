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

rules=$(printf 'set block-policy drop\npass quick on lo0\nblock drop out quick on %s all\n' "$interface")
/sbin/pfctl -a "$anchor" -f - <<<"$rules"
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
