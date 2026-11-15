#!/usr/bin/env bash
set -euo pipefail

ADB_SERIAL="G8S1KU062024019K"
KIOSK_PACKAGE="com.local.commandcenter"

if ! adb -s "$ADB_SERIAL" get-state 2>/dev/null | grep -qx device; then
  echo "Android tablet $ADB_SERIAL is not connected." >&2
  exit 1
fi

DEVICE_POLICY="$(adb -s "$ADB_SERIAL" shell dumpsys device_policy)"
if ! grep -Fq "package=${KIOSK_PACKAGE}" <<< "$DEVICE_POLICY"; then
  echo "Command Center is not the Device Owner; refusing to change kiosk policy." >&2
  exit 1
fi

LOCK_STATE="$(adb -s "$ADB_SERIAL" shell dumpsys activity activities \
  | sed -n 's/.*mLockTaskModeState=\([^ ]*\).*/\1/p' | head -1 | tr -d '\r')"
if [ "$LOCK_STATE" != "LOCKED" ]; then
  echo "Command Center LockTask is not active (state: ${LOCK_STATE:-unknown}); refusing to switch activities." >&2
  exit 1
fi

adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_WAKEUP
adb -s "$ADB_SERIAL" shell wm dismiss-keyguard
START_OUTPUT="$(adb -s "$ADB_SERIAL" shell am start \
  -n "${KIOSK_PACKAGE}/.MainActivity" 2>&1)"
printf '%s\n' "$START_OUTPUT"
if grep -q '^Error:' <<< "$START_OUTPUT"; then
  exit 1
fi

LOCK_STATE=""
for _ in $(seq 1 15); do
  RESUMED_ACTIVITY="$(adb -s "$ADB_SERIAL" shell dumpsys activity activities \
    | grep 'mResumedActivity' | head -1 || true)"
  LOCK_STATE="$(adb -s "$ADB_SERIAL" shell dumpsys activity activities \
    | sed -n 's/.*mLockTaskModeState=\([^ ]*\).*/\1/p' | head -1 | tr -d '\r')"
  [[ "$RESUMED_ACTIVITY" == *"${KIOSK_PACKAGE}"* && "$LOCK_STATE" == "LOCKED" ]] && break
  sleep 1
done
if [[ "$RESUMED_ACTIVITY" != *"${KIOSK_PACKAGE}"* ]]; then
  echo "Command Center did not become the foreground activity." >&2
  exit 1
fi
if [ "$LOCK_STATE" != "LOCKED" ]; then
  echo "LockTask was not retained while restoring the dashboard (state: ${LOCK_STATE:-unknown})." >&2
  exit 1
fi
