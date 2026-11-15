#!/usr/bin/env bash
set -euo pipefail

ADB_SERIAL="G8S1KU062024019K"
KIOSK_ADMIN="com.local.commandcenter/.AdminReceiver"
KIOSK_PACKAGE="com.local.commandcenter"

if ! adb -s "$ADB_SERIAL" get-state 2>/dev/null | grep -qx device; then
  echo "Android tablet $ADB_SERIAL is not connected." >&2
  exit 1
fi

DEVICE_POLICY="$(adb -s "$ADB_SERIAL" shell dumpsys device_policy)"
if ! grep -Fq "package=${KIOSK_PACKAGE}" <<< "$DEVICE_POLICY"; then
  adb -s "$ADB_SERIAL" shell dpm set-device-owner --user current \
    --name HoferHouse "$KIOSK_ADMIN"
fi

adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_WAKEUP
adb -s "$ADB_SERIAL" shell wm dismiss-keyguard
adb -s "$ADB_SERIAL" shell am force-stop org.lineageos.jelly 2>/dev/null || true
START_OUTPUT="$(adb -s "$ADB_SERIAL" shell am start \
  -n com.local.commandcenter/.MainActivity 2>&1)"
printf '%s\n' "$START_OUTPUT"
if grep -q '^Error:' <<< "$START_OUTPUT"; then
  exit 1
fi

for _ in $(seq 1 15); do
  RESUMED_ACTIVITY="$(adb -s "$ADB_SERIAL" shell dumpsys activity activities \
    | grep 'mResumedActivity' | head -1 || true)"
  [[ "$RESUMED_ACTIVITY" == *"${KIOSK_PACKAGE}"* ]] && break
  sleep 1
done
if [[ "$RESUMED_ACTIVITY" != *"${KIOSK_PACKAGE}"* ]]; then
  echo "Command Center did not become the foreground activity." >&2
  exit 1
fi
