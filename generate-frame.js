'use strict';
/**
 * Fallback Frame Generator
 * Emits a 1200x1600 RGBA PNG to assets/theme-frame.png with a fully
 * transparent window at x:100, y:240, w:1000, h:1180 (alpha === 0).
 * Exits early (code 0) if the frame already exists and is > 0 bytes.
 */
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const OUT = path.join(__dirname, 'assets', 'theme-frame.png');
const W = 1200;
const H = 1600;
const WIN = { left: 100, top: 240, width: 1000, height: 1180 };

function buildSvg() {
  // Cream base, plaid-style double inner trim in forest green + crimson,
  // festive header. The window area is later erased with dest-out.
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <rect x="0" y="0" width="${W}" height="${H}" fill="#FAF6F0"/>
  <!-- plaid bands around the window -->
  <g opacity="0.92">
    <rect x="52" y="192" width="1096" height="18" fill="#1B4332"/>
    <rect x="52" y="218" width="1096" height="8" fill="#8B0000"/>
    <rect x="52" y="1450" width="1096" height="8" fill="#8B0000"/>
    <rect x="52" y="1466" width="1096" height="18" fill="#1B4332"/>
    <rect x="52" y="192" width="18" height="1292" fill="#1B4332"/>
    <rect x="78" y="192" width="8" height="1292" fill="#8B0000"/>
    <rect x="1114" y="192" width="8" height="1292" fill="#8B0000"/>
    <rect x="1130" y="192" width="18" height="1292" fill="#1B4332"/>
  </g>
  <!-- outer double trim -->
  <rect x="24" y="24" width="1152" height="1552" fill="none" stroke="#1B4332" stroke-width="6"/>
  <rect x="40" y="40" width="1120" height="1520" fill="none" stroke="#8B0000" stroke-width="3"/>
  <!-- header -->
  <text x="600" y="118" text-anchor="middle"
        font-family="Liberation Serif, DejaVu Serif, serif"
        font-size="62" font-style="italic" font-weight="bold"
        fill="#1B4332">the Hofers Christmas 2026</text>
  <text x="600" y="166" text-anchor="middle"
        font-family="Liberation Serif, DejaVu Serif, serif"
        font-size="28" fill="#8B0000">&#10052; &#10022; &#10052;</text>
  <!-- footer -->
  <text x="600" y="1532" text-anchor="middle"
        font-family="Liberation Serif, DejaVu Serif, serif"
        font-size="30" font-style="italic" fill="#1B4332">Merry Christmas</text>
</svg>`);
}

async function ensureFrame() {
  if (fs.existsSync(OUT) && fs.statSync(OUT).size > 0) return OUT;

  fs.mkdirSync(path.dirname(OUT), { recursive: true });

  const base = await sharp(buildSvg()).png().toBuffer();

  // 100% opaque eraser the size of the window; dest-out makes it transparent.
  const eraser = await sharp({
    create: {
      width: WIN.width,
      height: WIN.height,
      channels: 4,
      background: { r: 0, g: 0, b: 0, alpha: 1 },
    },
  }).png().toBuffer();

  await sharp(base)
    .composite([{ input: eraser, left: WIN.left, top: WIN.top, blend: 'dest-out' }])
    .png()
    .toFile(OUT);

  // Programmatic verification: centre of the window must be alpha === 0.
  const { data, info } = await sharp(OUT).raw().toBuffer({ resolveWithObject: true });
  const idx = (800 * info.width + 600) * info.channels;
  const alpha = info.channels === 4 ? data[idx + 3] : 255;
  if (alpha !== 0) {
    throw new Error(`Frame verification failed: pixel (600,800) alpha=${alpha}, expected 0`);
  }
  return OUT;
}

if (require.main === module) {
  if (fs.existsSync(OUT) && fs.statSync(OUT).size > 0) {
    process.exit(0);
  }
  ensureFrame()
    .then((p) => console.log(`Frame written: ${p}`))
    .catch((err) => { console.error(err); process.exit(1); });
}

module.exports = { ensureFrame };
