'use strict';
const fs = require('fs');
const path = require('path');
const http = require('http');
const express = require('express');
const cors = require('cors');
const multer = require('multer');
const sharp = require('sharp');
const { Server } = require('socket.io');

const ROOT = __dirname;
const UPLOADS = path.join(ROOT, 'uploads');
const ASSETS = path.join(ROOT, 'assets');
const QR_DIR = path.join(ROOT, 'qr');
const CONFIG_PATH = path.join(ROOT, 'config.json');
const FRAME = path.join(ASSETS, 'theme-frame.png');

for (const d of [UPLOADS, ASSETS, QR_DIR]) fs.mkdirSync(d, { recursive: true });

function loadConfig() {
  return JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
}
let config = loadConfig();

const app = express();
const server = http.createServer(app);
const io = new Server(server);

app.set('trust proxy', true);
app.use(cors());
app.use(express.json({ limit: '60mb' }));

/* ---------- Proxy-aware in-memory rate limiter ---------- */
const buckets = new Map();
function clientKey(req) {
  return (
    req.headers['cf-connecting-ip'] ||
    req.headers['x-forwarded-for']?.split(',')[0]?.trim() ||
    req.ip
  );
}
function rateLimit(req, res, next) {
  const limit = (loadConfig().rateLimitPerMin) || 30;
  const key = clientKey(req);
  const now = Date.now();
  const windowStart = now - 60_000;
  const hits = (buckets.get(key) || []).filter((t) => t > windowStart);
  hits.push(now);
  buckets.set(key, hits);
  if (hits.length > limit) {
    return res.status(429).json({ error: 'Too many uploads — please wait a minute and try again' });
  }
  next();
}

/* ---------- Static ---------- */
app.use(express.static(path.join(ROOT, 'public')));
app.use('/uploads', express.static(UPLOADS, {
  setHeaders: (res) => res.setHeader('Cache-Control', 'public, max-age=31536000, immutable'),
}));
app.use('/qr', express.static(QR_DIR));

/* ---------- API ---------- */
app.get('/api/health', (req, res) => {
  res.json({ ok: true, uptime: process.uptime() });
});

app.get('/api/config', (req, res) => {
  let publicUrl = '';
  try {
    publicUrl = fs.readFileSync(path.join(QR_DIR, 'active-url.txt'), 'utf8').trim();
  } catch { publicUrl = ''; }
  res.json({ ...loadConfig(), publicUrl });
});

app.get('/api/photos', (req, res) => {
  const files = fs.readdirSync(UPLOADS)
    .filter((f) => /\.(jpe?g|png|webp)$/i.test(f))
    .map((f) => {
      const st = fs.statSync(path.join(UPLOADS, f));
      return { url: '/uploads/' + f, name: f, mtime: st.mtimeMs };
    })
    .sort((a, b) => b.mtime - a.mtime);
  res.json(files);
});

/* ---------- Upload: general candids ---------- */
const upload = multer({
  storage: multer.memoryStorage(),
  limits: {
    files: config.maxFilesPerRequest,
    fileSize: config.maxUploadMb * 1024 * 1024,
  },
  fileFilter: (req, file, cb) => cb(null, /^image\//.test(file.mimetype)),
});

app.post('/api/upload-general', rateLimit, (req, res) => {
  upload.array('photos')(req, res, async (err) => {
    if (err) {
      const code = err.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
      return res.status(code).json({ error: err.message });
    }
    if (!req.files || !req.files.length) {
      return res.status(400).json({ error: 'No image files received' });
    }
    if (req.files.reduce((n, f) => n + f.size, 0) > 200 * 1024 * 1024) {
      return res.status(413).json({ error: 'Batch too large — upload in smaller groups' });
    }
    const saved = [], skipped = [];
    for (const f of req.files) {
      if (!/^image\/(jpeg|png|webp)$/.test(f.mimetype)) {
        skipped.push(f.originalname);
        continue;
      }
      try {
        const filename = `candid-${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`;
        await sharp(f.buffer, { limitInputPixels: 40000000 })
          .rotate()
          .resize({ width: 1920, height: 1920, fit: 'inside', withoutEnlargement: true })
          .jpeg({ quality: 88 })
          .toFile(path.join(UPLOADS, filename));
        const url = `/uploads/${filename}`;
        saved.push(url);
        io.emit('new-photo', { url, type: 'candid' });
      } catch {
        skipped.push(f.originalname);
      }
    }
    return res.json({ ok: true, saved, skipped });
  });
});

/* ---------- Upload: photo booth composites ---------- */
const CELLS = {
  '1': [{ left: 100, top: 240, width: 1000, height: 1180 }],
  '2': [
    { left: 100, top: 240, width: 1000, height: 582 },
    { left: 100, top: 838, width: 1000, height: 582 },
  ],
  '4': [
    { left: 100, top: 240, width: 492, height: 582 },
    { left: 608, top: 240, width: 492, height: 582 },
    { left: 100, top: 838, width: 492, height: 582 },
    { left: 608, top: 838, width: 492, height: 582 },
  ],
  '6': [
    { left: 100, top: 240, width: 492, height: 383 },
    { left: 608, top: 240, width: 492, height: 383 },
    { left: 100, top: 639, width: 492, height: 383 },
    { left: 608, top: 639, width: 492, height: 383 },
    { left: 100, top: 1038, width: 492, height: 382 },
    { left: 608, top: 1038, width: 492, height: 382 },
  ],
};

app.post('/api/upload-booth', rateLimit, async (req, res) => {
  try {
    config = loadConfig();
    const { images, layout, filter } = req.body || {};
    const layoutKey = String(layout);
    if (!config.layouts[layoutKey]) {
      return res.status(400).json({ error: `Layout ${layoutKey} is not enabled` });
    }
    if (!config.filters[filter]) {
      return res.status(400).json({ error: `Filter ${filter} is not enabled` });
    }
    if (!Array.isArray(images) || images.length !== Number(layout)) {
      return res.status(400).json({ error: `Expected exactly ${layout} image(s) for layout ${layoutKey}` });
    }
    const cells = CELLS[layoutKey];
    if (!cells) return res.status(400).json({ error: `Unknown layout ${layoutKey}` });

    const composites = [];
    for (let i = 0; i < cells.length; i++) {
      const cell = cells[i];
      const raw = String(images[i]).replace(/^data:image\/[a-zA-Z0-9.+-]+;base64,/, '');
      const buf = Buffer.from(raw, 'base64');
      let pipe = sharp(buf, { limitInputPixels: 40000000 })
        .rotate()
        .resize(cell.width, cell.height, { fit: 'cover', position: 'centre' });
      if (filter === 'bw') {
        pipe = pipe.grayscale().modulate({ brightness: 1.03, contrast: 1.15 });
      }
      composites.push({
        input: await pipe.png().toBuffer(),
        left: cell.left,
        top: cell.top,
      });
    }

    const baseWithCells = await sharp({
      create: {
        width: 1200, height: 1600, channels: 4,
        background: { r: 250, g: 246, b: 240, alpha: 1 }, // #FAF6F0
      },
    }).composite(composites).png().toBuffer();

    if (!fs.existsSync(FRAME)) {
      const { ensureFrame } = require('./generate-frame');
      await ensureFrame();
    }

    const filename = `booth-${Date.now()}.jpg`;
    await sharp(baseWithCells)
      .composite([{ input: FRAME, left: 0, top: 0 }])
      .jpeg({ quality: 92 })
      .toFile(path.join(UPLOADS, filename));

    const url = `/uploads/${filename}`;
    io.emit('new-photo', { url, type: 'booth' });
    return res.json({ ok: true, url });
  } catch (e) {
    console.error('upload-booth failed:', e);
    return res.status(400).json({ error: 'Could not process those photos — please try again' });
  }
});

/* ---------- Retention ---------- */
function prune() {
  try {
    const max = loadConfig().retentionMaxFiles || 800;
    const files = fs.readdirSync(UPLOADS)
      .filter((f) => /\.(jpe?g|png|webp)$/i.test(f))
      .map((f) => ({ f, mtime: fs.statSync(path.join(UPLOADS, f)).mtimeMs }))
      .sort((a, b) => a.mtime - b.mtime); // oldest first
    while (files.length > max) {
      const victim = files.shift();
      fs.unlinkSync(path.join(UPLOADS, victim.f));
    }
  } catch (e) {
    console.error('retention prune failed:', e);
  }
}

/* ---------- Boot ---------- */
(async () => {
  try {
    if (!fs.existsSync(FRAME)) {
      const { ensureFrame } = require('./generate-frame');
      await ensureFrame();
      console.log('Generated fallback theme frame.');
    }
  } catch (e) {
    console.error('Frame generation on boot failed:', e);
  }
  prune();
  setInterval(prune, 60 * 60 * 1000).unref();

  const PORT = process.env.PORT || 3000;
  server.listen(PORT, () => console.log(`party-gallery listening on :${PORT}`));
})();
