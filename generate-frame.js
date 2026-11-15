'use strict';
/**
 * Fallback Frame Generator
 * Emits a 1200x1920 RGBA PNG to assets/theme-frame.png with a fully
 * transparent window at x:70, y:250, w:1060, h:1420 (alpha === 0).
 */
const fs = require('fs');
const path = require('path');
const sharp = require('sharp');

const OUT = path.join(__dirname, 'assets', 'theme-frame.png');
const W = 1200;
const H = 1920;
const WIN = { left: 70, top: 250, width: 1060, height: 1420 };

function buildSvg() {
  // Cream base, plaid-style double inner trim in forest green + crimson,
  // festive header. The window area is later erased with dest-out.
  return Buffer.from(`<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
  <rect x="0" y="0" width="${W}" height="${H}" fill="#FAF6F0"/>
  <!-- plaid bands around the window -->
  <g opacity="0.92">
    <rect x="36" y="210" width="1128" height="18" fill="#1B4332"/>
    <rect x="36" y="236" width="1128" height="8" fill="#8B0000"/>
    <rect x="36" y="1690" width="1128" height="8" fill="#8B0000"/>
    <rect x="36" y="1706" width="1128" height="18" fill="#1B4332"/>
    <rect x="36" y="210" width="18" height="1514" fill="#1B4332"/>
    <rect x="62" y="210" width="8" height="1514" fill="#8B0000"/>
    <rect x="1130" y="210" width="8" height="1514" fill="#8B0000"/>
    <rect x="1146" y="210" width="18" height="1514" fill="#1B4332"/>
  </g>
  <!-- outer double trim -->
  <rect x="12" y="12" width="1176" height="1896" fill="none" stroke="#1B4332" stroke-width="6"/>
  <rect x="28" y="28" width="1144" height="1864" fill="none" stroke="#8B0000" stroke-width="3"/>
  <!-- header -->
  <text x="600" y="118" text-anchor="middle"
        font-family="Liberation Serif, DejaVu Serif, serif"
        font-size="62" font-style="italic" font-weight="bold"
        fill="#1B4332">the Hofers Christmas 2026</text>
  <text x="600" y="166" text-anchor="middle"
        font-family="Liberation Serif, DejaVu Serif, serif"
        font-size="28" fill="#8B0000">&#10052; &#10022; &#10052;</text>
  <!-- footer -->
  <text x="600" y="1852" text-anchor="middle"
        font-family="Liberation Serif, DejaVu Serif, serif"
        font-size="30" font-style="italic" fill="#1B4332">Merry Christmas</text>
</svg>`);
}

async function ensureFrame() {
  if (fs.existsSync(OUT) && fs.statSync(OUT).size > 0) {
    const metadata = await sharp(OUT).metadata();
    if (metadata.width === W && metadata.height === H) return OUT;
  }

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
  const idx = (960 * info.width + 600) * info.channels;
  const alpha = info.channels === 4 ? data[idx + 3] : 255;
  if (alpha !== 0) {
    throw new Error(`Frame verification failed: pixel (600,960) alpha=${alpha}, expected 0`);
  }
  return OUT;
}

if (require.main === module) {
  ensureFrame()
    .then((p) => console.log(`Frame written: ${p}`))
    .catch((err) => { console.error(err); process.exit(1); });
}

module.exports = { ensureFrame };
