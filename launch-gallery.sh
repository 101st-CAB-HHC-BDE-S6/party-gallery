#!/usr/bin/env bash
# Launch the Party Gallery stack on the host it runs on (target: /opt/party-gallery).
set -euo pipefail

cd /opt/party-gallery

# Refresh .env dynamically so UID/GID is never stale across invocations.
HOST_UID="${SUDO_UID:-$(id -u)}"
HOST_GID="${SUDO_GID:-$(id -g)}"
printf 'HOST_UID=%s\nHOST_GID=%s\n' "$HOST_UID" "$HOST_GID" > /opt/party-gallery/.env
chown -R "${HOST_UID}:${HOST_GID}" /opt/party-gallery/{uploads,qr,assets} || true

docker compose up -d --build

# Wait for gallery-app health.
for _ in $(seq 1 30); do
  if curl -fsS http://localhost:3000/api/health >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
curl -fsS http://localhost:3000/api/health >/dev/null

# Ensure the fallback frame exists.
docker compose exec -T gallery-app node generate-frame.js

# Detect LAN IP.
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')
LOCAL_IP=${LOCAL_IP:-192.168.1.139}

# Poll cloudflared logs (no -f, avoids SIGPIPE) for the quick-tunnel URL.
TUNNEL_URL=""
for _ in $(seq 1 30); do
  TUNNEL_URL=$(docker compose logs cloudflared 2>&1 \
    | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -n1 || true)
  [ -n "$TUNNEL_URL" ] && break
  sleep 1
done
if [ -z "$TUNNEL_URL" ]; then
  echo "WARN: no tunnel URL after 30s — falling back to LAN (camera will need the tunnel)" >&2
  TUNNEL_URL="http://${LOCAL_IP}:3000"
fi

# Publish the active URL and generate both QR PNGs inside the container.
printf '%s\n' "$TUNNEL_URL" > /opt/party-gallery/qr/active-url.txt
docker compose exec -T gallery-app node make-qr.js "${TUNNEL_URL}/upload.html" "/app/qr/upload-qr.png"
docker compose exec -T gallery-app node make-qr.js "${TUNNEL_URL}/booth.html" "/app/qr/booth-qr.png"
[ -s /opt/party-gallery/qr/upload-qr.png ] && [ -s /opt/party-gallery/qr/booth-qr.png ]

# Guarded ADB tablet provisioning (pipefail-safe when no device is attached).
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
  adb -s "$ADB_SERIAL" shell am start -a android.intent.action.VIEW -d "http://${LOCAL_IP}:3000/gallery.html" -n "$FULLY_ACT"
else
  echo "WARN: no ADB device attached — skipping tablet provisioning" >&2
fi

cat <<EOF

================ Party Gallery is live ================
Local Gallery URL:        http://${LOCAL_IP}:3000/gallery.html
Printable QR Sheet URL:   http://${LOCAL_IP}:3000/print-qrs.html
Public Upload URL:        ${TUNNEL_URL}/upload.html
Public Photo Booth URL:   ${TUNNEL_URL}/booth.html
Note: quick-tunnel URLs rotate if cloudflared restarts — rerun this script to refresh the QR codes.
=======================================================
EOF
