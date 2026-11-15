#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

ADB_SERIAL="G8S1KU062024019K"
KIOSK_PACKAGE="com.local.commandcenter"
LOCAL_IP="${LOCAL_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')}"
LOCAL_IP="${LOCAL_IP:-192.168.1.139}"
GALLERY_URL="http://${LOCAL_IP}:3000/gallery.html"
HEALTH_URL="http://localhost:3000/api/health"

mkdir -p qr

if ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
  npm install --omit=dev --no-save --package-lock=false
  nohup npm start >> qr/server.log 2>&1 </dev/null &
  printf '%s\n' "$!" > qr/server.pid
  for _ in $(seq 1 30); do
    curl -fsS "$HEALTH_URL" >/dev/null 2>&1 && break
    sleep 1
  done
fi
curl -fsS "$HEALTH_URL" >/dev/null

TUNNEL_URL=""
if [ -s qr/active-url.txt ]; then
  CANDIDATE_URL="$(tr -d '\r\n' < qr/active-url.txt)"
  if [[ "$CANDIDATE_URL" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]] \
    && curl --max-time 10 -fsS "$CANDIDATE_URL/api/health" >/dev/null 2>&1; then
    TUNNEL_URL="$CANDIDATE_URL"
  fi
fi

if [ -z "$TUNNEL_URL" ]; then
  CLOUDFLARED="${CLOUDFLARED:-$HOME/.local/bin/cloudflared}"
  if [ ! -x "$CLOUDFLARED" ]; then
    CLOUDFLARED="$(command -v cloudflared || true)"
  fi
  if [ -z "$CLOUDFLARED" ] || [ ! -x "$CLOUDFLARED" ]; then
    echo "cloudflared is required to create the public upload tunnel." >&2
    exit 1
  fi

  TUNNEL_LOG="$PROJECT_DIR/qr/cloudflared.log"
  nohup "$CLOUDFLARED" tunnel --url http://localhost:3000 --no-autoupdate \
    > "$TUNNEL_LOG" 2>&1 </dev/null &
  printf '%s\n' "$!" > qr/cloudflared.pid
  for _ in $(seq 1 30); do
    TUNNEL_URL="$(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | tail -n 1 || true)"
    [ -n "$TUNNEL_URL" ] && break
    sleep 1
  done
  if [ -z "$TUNNEL_URL" ]; then
    echo "cloudflared did not provide a quick-tunnel URL:" >&2
    tail -30 "$TUNNEL_LOG" >&2
    exit 1
  fi
fi

printf '%s\n' "$TUNNEL_URL" > qr/active-url.txt
node make-qr.js "${TUNNEL_URL}/upload.html" qr/upload-qr.png
node make-qr.js "${TUNNEL_URL}/booth.html" qr/booth-qr.png
curl --max-time 10 -fsS "${TUNNEL_URL}/api/config" >/dev/null

if ! adb -s "$ADB_SERIAL" get-state 2>/dev/null | grep -qx device; then
  echo "Android tablet $ADB_SERIAL is not connected." >&2
  exit 1
fi

DEVICE_POLICY="$(adb -s "$ADB_SERIAL" shell dumpsys device_policy)"
if ! grep -Fq "package=${KIOSK_PACKAGE}" <<< "$DEVICE_POLICY"; then
  echo "Command Center is not the Device Owner; refusing to switch activities." >&2
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
  -n "${KIOSK_PACKAGE}/.MainActivity" \
  -a android.intent.action.VIEW -d "$GALLERY_URL" 2>&1)"
printf '%s\n' "$START_OUTPUT"
if grep -q '^Error:' <<< "$START_OUTPUT"; then
  exit 1
fi

RESUMED_ACTIVITY=""
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
  echo "LockTask was not retained while opening the gallery (state: ${LOCK_STATE:-unknown})." >&2
  exit 1
fi

cat <<EOF

================ Party Gallery is live ================
Local Gallery URL:        ${GALLERY_URL}
Printable QR Sheet URL:   http://${LOCAL_IP}:3000/print-qrs.html
Public Upload URL:        ${TUNNEL_URL}/upload.html
Public Photo Booth URL:   ${TUNNEL_URL}/booth.html
Kiosk App:                ${KIOSK_PACKAGE}/.MainActivity
=======================================================
EOF
