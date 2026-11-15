#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

ADB_SERIAL="G8S1KU062024019K"
KIOSK_PACKAGE="com.local.commandcenter"

stop_process_tree() {
  local parent_pid="$1"
  local expected_command="$2"
  local child_pid child_command child_cwd

  while IFS= read -r child_pid; do
    [[ "$child_pid" =~ ^[1-9][0-9]*$ ]] || continue
    child_command="$(ps -p "$child_pid" -o args= 2>/dev/null || true)"
    child_cwd="$(readlink "/proc/$child_pid/cwd" 2>/dev/null || true)"
    if [[ "$child_cwd" == "$PROJECT_DIR" \
        && ( "$child_command" == *"$expected_command"* \
             || ( "$expected_command" == "node server.js" \
                  && ( "$child_command" == *"npm start"* || "$child_command" == *"npm-cli.js start"* ) ) ) ]]; then
      stop_process_tree "$child_pid" "$expected_command"
      kill "$child_pid" 2>/dev/null || true
      for _ in $(seq 1 10); do
        local child_state
        child_state="$(ps -p "$child_pid" -o stat= 2>/dev/null || true)"
        [[ -z "$child_state" || "$child_state" == Z* ]] && break
        sleep 1
      done
    fi
  done < <(ps -eo pid=,ppid= | awk -v parent="$parent_pid" '$2 == parent {print $1}')
}

stop_recorded_process() {
  local pid_file="$1"
  local expected_command="$2"
  local pid command process_cwd state valid_command=false

  if [ ! -s "$pid_file" ]; then
    return
  fi
  IFS= read -r pid < "$pid_file"
  if [[ ! "$pid" =~ ^[1-9][0-9]*$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pid_file"
    return
  fi

  state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
  command="$(ps -p "$pid" -o args= 2>/dev/null || true)"
  process_cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
  if [[ "$command" == *"$expected_command"* ]]; then
    valid_command=true
  elif [[ "$expected_command" == "node server.js" \
      && ( "$command" == *"npm start"* || "$command" == *"npm-cli.js start"* ) ]]; then
    valid_command=true
  fi
  if [[ -z "$state" || "$state" == Z* ]]; then
    rm -f "$pid_file"
    return
  fi
  if [[ "$process_cwd" != "$PROJECT_DIR" || "$valid_command" != true ]]; then
    echo "Refusing to stop unverified PID $pid from $pid_file." >&2
    return 1
  fi

  stop_process_tree "$pid" "$expected_command"
  kill "$pid"
  for _ in $(seq 1 10); do
    state="$(ps -p "$pid" -o stat= 2>/dev/null || true)"
    [[ -z "$state" || "$state" == Z* ]] && break
    sleep 1
  done
  if [[ -n "$state" && "$state" != Z* ]]; then
    echo "Process $pid did not stop after SIGTERM." >&2
    return 1
  fi
  rm -f "$pid_file"
}

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
adb -s "$ADB_SERIAL" shell settings put system screen_off_timeout 600000
adb -s "$ADB_SERIAL" shell settings put system accelerometer_rotation 0
adb -s "$ADB_SERIAL" shell settings put system user_rotation 1
START_OUTPUT="$(adb -s "$ADB_SERIAL" shell am start \
  -n "${KIOSK_PACKAGE}/.MainActivity" \
  -a android.intent.action.VIEW -d "commandcenter://camwall" -f 0x24000000 2>&1)"
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

stop_recorded_process "$PROJECT_DIR/qr/server.pid" "node server.js"
stop_recorded_process "$PROJECT_DIR/qr/cloudflared.pid" "tunnel --url http://localhost:3000"
