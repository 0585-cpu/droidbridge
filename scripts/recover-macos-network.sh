#!/bin/bash
# Explicit recovery/update: stops only DroidBridge, restores its network state, installs the
# same-team signed helper, and leaves the tunnel stopped. Never disables the global firewall.
set -euo pipefail
if [[ "$EUID" -ne 0 ]]; then
  echo 'Run this recovery script with sudo; macOS administrator authorization is required.' >&2
  exit 77
fi
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_helper="${1:-$repo/build/DerivedData/Build/Products/Release/DroidBridge.app/Contents/Library/LaunchDaemons/DroidBridgeHelper}"
destination=/Library/PrivilegedHelperTools/io.droidbridge.helper
plist=/Library/LaunchDaemons/io.droidbridge.helper.plist
operation_lock=/Library/PrivilegedHelperTools/.io.droidbridge.operation.lock
[[ -x "$source_helper" && -x "$destination" && -f "$plist" ]] || { echo 'Required helper or launch plist is missing.' >&2; exit 1; }
team="$(/usr/bin/codesign -dv "$destination" 2>&1 | /usr/bin/awk -F= '$1 == "TeamIdentifier" {print $2}')"
[[ "$team" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Cannot verify the installed signing team.' >&2; exit 1; }
requirement="identifier \"io.droidbridge.helper\" and anchor apple generic and certificate leaf[subject.OU] = \"$team\""
/usr/bin/codesign --verify --strict "-R=$requirement" "$source_helper"
/usr/bin/shlock -f "$operation_lock" -p $$ || { echo 'Another DroidBridge helper operation is running.' >&2; exit 73; }
stage=''
plist_stage=''
plist_replaced=0
restart=0
replaced=0
cleanup() {
  status=$?
  if [[ "$status" -ne 0 && "$replaced" == 1 ]]; then
    # A failed bootstrap may have registered the new job partially. Stop it before restoring.
    if ! /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1 ||
       /bin/launchctl bootout system/io.droidbridge.helper; then
      /usr/bin/install -o root -g wheel -m 0755 "$destination.previous" "$destination" || status=1
      if [[ "$plist_replaced" == 1 ]]; then
        /usr/bin/install -o root -g wheel -m 0644 "$plist.previous" "$plist" || status=1
      fi
    else
      echo 'Could not stop the replacement helper; its previous binary is retained for recovery.' >&2
      restart=0
    fi
  fi
  if [[ "$restart" == 1 ]] && ! /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then
    /bin/launchctl bootstrap system "$plist" || status=1
  fi
  [[ -z "$stage" ]] || /bin/rm -f "$stage"
  [[ -z "$plist_stage" ]] || /bin/rm -f "$plist_stage"
  /bin/rm -f "$operation_lock"
  exit "$status"
}
trap cleanup EXIT
stage="$(/usr/bin/mktemp /Library/PrivilegedHelperTools/.io.droidbridge.recovery-helper.XXXXXX)"
/usr/bin/install -o root -g wheel -m 0755 "$source_helper" "$stage"
/usr/bin/codesign --verify --strict "-R=$requirement" "$stage"
plist_stage="$(/usr/bin/mktemp /Library/LaunchDaemons/.io.droidbridge.recovery-plist.XXXXXX)"
/usr/bin/install -o root -g wheel -m 0644 "$plist" "$plist_stage"
/usr/bin/plutil -replace KeepAlive -json '{"SuccessfulExit":false}' "$plist_stage"
if /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then
  restart=1
  /bin/launchctl bootout system/io.droidbridge.helper
fi
if /bin/launchctl print system/io.droidbridge.helper >/dev/null 2>&1; then
  echo 'The previous helper is still registered; recovery was not started.' >&2
  exit 1
fi
"$stage" --recover-network
# Retain a rollback copy of the previously installed signed helper.
/usr/bin/install -o root -g wheel -m 0755 "$destination" "$destination.previous"
/usr/bin/install -o root -g wheel -m 0644 "$plist" "$plist.previous"
/bin/mv -f "$stage" "$destination"
stage=''
replaced=1
plist_replaced=1
/bin/mv -f "$plist_stage" "$plist"
plist_stage=''
restart=1
/bin/launchctl bootstrap system "$plist"
restart=0
echo 'DroidBridge helper updated; the USB tunnel remains stopped.'
