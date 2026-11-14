#!/usr/bin/env bash
# Stop the Party Gallery and restore the camera-wall dashboard on the tablet.
set -euo pipefail

cd /opt/party-gallery && docker compose down || true

# Search in explicit order for the existing camera wall deployment script.
CAMWALL=""
for candidate in \
  "/home/${SUDO_USER:-$USER}/deploy-camwall.sh" \
  "/root/deploy-camwall.sh" \
  "/opt/deploy-camwall.sh" \
  "/opt/camwall/deploy-camwall.sh"; do
  if [ -f "$candidate" ]; then
    CAMWALL="$candidate"
    break
  fi
done

if [ -n "$CAMWALL" ]; then
  echo "Restoring camera wall via: $CAMWALL"
  exec "$CAMWALL"
fi

echo "WARN: deploy-camwall.sh not found — relaunching Fully Kiosk to its default start page" >&2
ADB_SERIAL=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}' || true)
if [ -n "$ADB_SERIAL" ]; then
  FULLY_ACT=$(adb -s "$ADB_SERIAL" shell cmd package resolve-activity --brief de.ozerov.fully 2>/dev/null | tail -n1 | tr -d '\r' || true)
  case "$FULLY_ACT" in
    */*) ;;
    *) FULLY_ACT="de.ozerov.fully/.MainActivity" ;;
  esac
  adb -s "$ADB_SERIAL" shell input keyevent KEYCODE_WAKEUP
  adb -s "$ADB_SERIAL" shell wm dismiss-keyguard
  adb -s "$ADB_SERIAL" shell settings put global stay_on_while_plugged_in 7
  adb -s "$ADB_SERIAL" shell am start -n "$FULLY_ACT"
else
  echo "WARN: no ADB device attached — skipping tablet provisioning" >&2
fi
