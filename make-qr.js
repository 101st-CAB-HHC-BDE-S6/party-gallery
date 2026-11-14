'use strict';
/** Usage: node make-qr.js <targetUrl> <outputPath> */
const fs = require('fs');
const path = require('path');
const QRCode = require('qrcode');

async function main() {
  const [, , targetUrl, outputPath] = process.argv;
  if (!targetUrl || !outputPath) {
    console.error('Usage: node make-qr.js <targetUrl> <outputPath>');
    process.exit(1);
  }
  fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
  await QRCode.toFile(outputPath, targetUrl, {
    type: 'png',
    width: 600,
    margin: 2,
    errorCorrectionLevel: 'M',
    color: { dark: '#000000', light: '#FFFFFF' },
  });
  console.log(`QR written: ${outputPath} -> ${targetUrl}`);
}

main().catch((err) => { console.error(err); process.exit(1); });
