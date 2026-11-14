#!/usr/bin/env bash
set -euo pipefail

ADB_SERIAL="G8S1KU062024019K"

if ! adb -s "$ADB_SERIAL" get-state 2>/dev/null | grep -qx device; then
  echo "Android tablet $ADB_SERIAL is not connected." >&2
  exit 1
fi

adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_WAKEUP
adb -s "$ADB_SERIAL" shell wm dismiss-keyguard
START_OUTPUT="$(adb -s "$ADB_SERIAL" shell am start \
  -n com.local.commandcenter/.MainActivity 2>&1)"
printf '%s\n' "$START_OUTPUT"
if grep -q '^Error:' <<< "$START_OUTPUT"; then
  exit 1
fi
