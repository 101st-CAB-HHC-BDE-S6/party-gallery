#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

ADB_SERIAL="G8S1KU062024019K"
KIOSK_PACKAGE="com.local.commandcenter"
LOCAL_IP="${LOCAL_IP:-192.168.1.139}"
GALLERY_URL="http://${LOCAL_IP}:3000/gallery.html"
HEALTH_URL="http://localhost:3000/api/health"

mkdir -p qr

REMOTE_URL="$(git remote get-url origin)"
if [[ "$REMOTE_URL" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
  REPOSITORY_SLUG="${BASH_REMATCH[1]}"
else
  echo "Could not determine the GitHub repository from origin: $REMOTE_URL" >&2
  exit 1
fi
GITHUB_OWNER="${REPOSITORY_SLUG%/*}"
REPOSITORY_NAME="${REPOSITORY_SLUG#*/}"
PAGES_BASE_URL="https://${GITHUB_OWNER,,}.github.io/${REPOSITORY_NAME,,}"

find_running_tunnel_url() {
  local pid command process_cwd logfile candidate
  while IFS= read -r pid; do
    command="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    process_cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    [[ "$command" == *"cloudflared tunnel --url http://localhost:3000"* ]] || continue
    [[ "$process_cwd" == "$PROJECT_DIR" || "$command" == *"$PROJECT_DIR/qr/cloudflared.log"* ]] || continue
    logfile="$PROJECT_DIR/qr/cloudflared.log"
    if [[ "$command" =~ --logfile[[:space:]]([^[:space:]]+) ]]; then
      logfile="${BASH_REMATCH[1]}"
    fi
    while IFS= read -r candidate; do
      if curl --max-time 10 -fsS "${candidate}/api/health" >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(grep -Eo 'https://[a-z0-9-]+\.trycloudflare\.com' "$logfile" 2>/dev/null | sort -u)
  done < <(ps -eo pid=,comm=,args= | awk '$2 == "cloudflared" && index($0, "tunnel --url http://localhost:3000") {print $1}')
  return 1
}

find_server_pid() {
  local pid command process_cwd
  while IFS= read -r pid; do
    command="$(ps -p "$pid" -o args= 2>/dev/null || true)"
    process_cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
    if [[ "$process_cwd" == "$PROJECT_DIR" && "$command" == *"node server.js"* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(ps -eo pid=,args= | awk '$0 ~ /(^|[[:space:]])node server[.]js$/ {print $1}')
  return 1
}

if ! curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
  if ss -ltn | grep -q ':3000 '; then
    echo "Port 3000 is already listening but Party Gallery is not healthy; refusing to start a duplicate server." >&2
    exit 1
  fi
  npm install --omit=dev --no-save --package-lock=false
  (
    set -m
    nohup npm start >> "$PROJECT_DIR/qr/server.log" 2>&1 </dev/null &
    echo "$!" > "$PROJECT_DIR/qr/server.pid"
    disown "$!"
  )
  for _ in $(seq 1 30); do
    curl -fsS "$HEALTH_URL" >/dev/null 2>&1 && break
    sleep 1
  done
fi
curl -fsS "$HEALTH_URL" >/dev/null
if [ ! -s qr/server.pid ]; then
  SERVER_PID="$(find_server_pid)" || {
    echo "Could not identify the Party Gallery node server process." >&2
    exit 1
  }
  printf '%s\n' "$SERVER_PID" > qr/server.pid
fi

TUNNEL_URL=""
if [ -s qr/active-url.txt ]; then
  CANDIDATE_URL="$(tr -d '\r\n' < qr/active-url.txt)"
  if [[ "$CANDIDATE_URL" =~ ^https://[a-z0-9-]+\.trycloudflare\.com$ ]] \
    && curl --max-time 10 -fsS "$CANDIDATE_URL/api/health" >/dev/null 2>&1; then
    TUNNEL_URL="$CANDIDATE_URL"
  fi
fi

if [ -z "$TUNNEL_URL" ]; then
  TUNNEL_URL="$(find_running_tunnel_url || true)"
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
  : > "$TUNNEL_LOG"
  (
    set -m
    nohup "$CLOUDFLARED" tunnel --url http://localhost:3000 --no-autoupdate \
      --logfile "$TUNNEL_LOG" >/dev/null 2>&1 </dev/null &
    echo "$!" > "$PROJECT_DIR/qr/cloudflared.pid"
    disown "$!"
  )
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
  TUNNEL_READY=0
  for _ in $(seq 1 30); do
    if curl --max-time 3 -fsS "${TUNNEL_URL}/api/health" >/dev/null 2>&1; then
      TUNNEL_READY=1
      break
    fi
    sleep 1
  done
  if [ "$TUNNEL_READY" -ne 1 ]; then
    echo "Quick tunnel did not become ready at ${TUNNEL_URL}." >&2
    tail -30 "$TUNNEL_LOG" >&2
    exit 1
  fi
fi

printf '%s\n' "$TUNNEL_URL" > qr/active-url.txt
curl --max-time 10 -fsS "${TUNNEL_URL}/api/config" >/dev/null

if [[ "$(git branch --show-current)" != "main" ]]; then
  echo "Tunnel configuration publishing requires the main branch." >&2
  exit 1
fi
if ! git diff --cached --quiet; then
  echo "Refusing to publish tunnel configuration while unrelated changes are staged." >&2
  exit 1
fi
node - "$TUNNEL_URL" <<'NODE'
const fs = require('fs');
const [url] = process.argv.slice(2);
const target = 'public/tunnel-config.json';
let current = '';
try { current = JSON.parse(fs.readFileSync(target, 'utf8')).url || ''; } catch {}
if (current !== url) {
  const temporary = `${target}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify({ url, updatedAt: new Date().toISOString() }, null, 2)}\n`);
  fs.renameSync(temporary, target);
}
NODE
if ! git diff --quiet -- public/tunnel-config.json; then
  git add public/tunnel-config.json
  git commit -m "Update active public tunnel endpoint" \
    -m "Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
  git push origin main
fi

QR_BASE_URL="$TUNNEL_URL"
for _ in $(seq 1 30); do
  PUBLISHED_CONFIG="$(curl --max-time 5 -fsSL \
    "${PAGES_BASE_URL}/tunnel-config.json?t=$(date +%s)" 2>/dev/null || true)"
  PUBLISHED_TUNNEL="$(node -e 'try { process.stdout.write(JSON.parse(process.argv[1]).url || "") } catch {}' \
    "$PUBLISHED_CONFIG")"
  if [ "$PUBLISHED_TUNNEL" = "$TUNNEL_URL" ] \
    && curl --max-time 5 -fsSL "${PAGES_BASE_URL}/upload.html" >/dev/null 2>&1; then
    QR_BASE_URL="$PAGES_BASE_URL"
    break
  fi
  sleep 2
done
printf '%s\n' "$QR_BASE_URL" > qr/qr-base-url.txt
node make-qr.js "${QR_BASE_URL}/upload.html" qr/upload-qr.png
node make-qr.js "${QR_BASE_URL}/booth.html" qr/booth-qr.png
node make-qr.js "${QR_BASE_URL}/react.html" qr/react-qr.png

if ! adb -s "$ADB_SERIAL" get-state 2>/dev/null | grep -qx device; then
  echo "Android tablet $ADB_SERIAL is not connected." >&2
  exit 1
fi

adb -s "$ADB_SERIAL" shell settings put system accelerometer_rotation 0
adb -s "$ADB_SERIAL" shell settings put system screen_off_timeout 2147483647
adb -s "$ADB_SERIAL" shell settings put system user_rotation 0

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
ENCODED_URL="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$GALLERY_URL")"
START_OUTPUT="$(adb -s "$ADB_SERIAL" shell am start \
  -n "${KIOSK_PACKAGE}/.MainActivity" \
  -a android.intent.action.VIEW -d "commandcenter://gallery?url=${ENCODED_URL}" \
  -f 0x24000000 2>&1)"
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
Public Upload URL:        ${QR_BASE_URL}/upload.html
Public Photo Booth URL:   ${QR_BASE_URL}/booth.html
Public Reactions URL:     ${QR_BASE_URL}/react.html
Kiosk App:                ${KIOSK_PACKAGE}/.MainActivity
=======================================================
EOF
