# Party Gallery — Verification Record

## Environment reality check (2026-11-13, run from Muse's VM)
- This VM is NOT the target server: hostname `htch-runtime`, IP `198.19.0.2`, Ubuntu 24.04.
- `docker`: NOT installed here. `adb`: NOT installed here. No tablet attached to this VM.
- Target `192.168.1.139`: direct TCP unreachable from this VM (sandbox network, `Operation not permitted`); Tailscale status: `Not connected`.
- Therefore Docker containers, Cloudflare tunnel, and ADB tablet provisioning could NOT be executed or verified from here. Nothing below claims they were.

## Locally verified (real output, same code that ships in the containers)
- `bash -n` / `node --check`: server.js, generate-frame.js, make-qr.js, launch-gallery.sh, restore-camwall.sh — all OK.
- `package.json` / `config.json` parse as JSON; `docker-compose.yml` parses as YAML.
- `npm list` confirms exact pins: express@4.21.2, socket.io@4.8.1, multer@1.4.5-lts.1, sharp@0.33.5, qrcode@1.5.4, cors@2.8.5.
- Frame: `node generate-frame.js` wrote 1200x1600 RGBA PNG (39,386 bytes); programmatic raw check: pixel (600,800) alpha = 0. PASS.
- QR: `node make-qr.js` wrote upload-qr.png (3,718 bytes) and booth-qr.png (3,780 bytes), non-zero. PASS (test QRs removed after validation; launch-gallery.sh regenerates them against the live tunnel URL).
- Server run directly with Node (no Docker):
  - `GET /api/health` → HTTP 200, `{"ok":true,"uptime":...}`
  - `GET /api/config` → valid JSON including non-empty `publicUrl` from `qr/active-url.txt`
  - `GET /api/photos` → `[]` when empty, newest-first list after uploads
  - `POST /api/upload-booth` layout "1" → HTTP 200, framed 1200x1600 JPEG written to uploads/
  - `POST /api/upload-booth` layout "6", filter "bw", 6 images → HTTP 200, 1200x1600 JPEG
  - `POST /api/upload-booth` layout "4" with 1 image → HTTP 400 (validation works)
  - `POST /api/upload-general` with 800x600 JPEG → HTTP 200, `{"saved":[...],"skipped":[]}`
  - All four pages (/gallery.html, /upload.html, /booth.html, /print-qrs.html) → HTTP 200; all inline scripts pass `node --check`.

## NOT verified (requires the real server / tablet)
- `docker compose ps`: gallery-app (healthy), cloudflared (running)
- Cloudflare quick-tunnel URL acquisition in launch-gallery.sh
- Definition-of-done health check against http://192.168.1.139:3000 (or localhost on that server)
- ADB: Fully Kiosk VIEW intent resolving and gallery.html displayed on the LineageOS 18 tablet

## To deploy on the real server (192.168.1.139)
1. Copy this project to `/opt/party-gallery` on that server.
2. Run: `cd /opt/party-gallery && chmod +x launch-gallery.sh restore-camwall.sh && ./launch-gallery.sh`
3. Verify: `docker compose ps`, `curl -s http://localhost:3000/api/config`, check `qr/upload-qr.png` and `qr/booth-qr.png` are non-zero.
4. To return the tablet to the camera wall afterwards: `./restore-camwall.sh`
