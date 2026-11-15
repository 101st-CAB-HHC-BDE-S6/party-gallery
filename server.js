'use strict';
const fs = require('fs');
const fsp = require('fs/promises');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const express = require('express');
const cors = require('cors');
const multer = require('multer');
const sharp = require('sharp');
const { Server } = require('socket.io');
const { ensureFrame } = require('./generate-frame');

sharp.concurrency(2);

const ROOT = __dirname;
const UPLOADS = path.join(ROOT, 'uploads');
const TMP = path.join(ROOT, 'tmp');
const ASSETS = path.join(ROOT, 'assets');
const QR_DIR = path.join(ROOT, 'qr');
const CONFIG_PATH = path.join(ROOT, 'config.json');
const FRAME = path.join(ASSETS, 'theme-frame.png');
const PAGES_BASE_URL = 'https://101st-cab-hhc-bde-s6.github.io/party-gallery';

const DEFAULTS = {
  eventTitle: 'the Hofers Christmas 2026',
  filters: { bw: true, color: true },
  idleResumeMs: 30000,
  attractIdleMs: 90000,
  layouts: { 1: true, 2: true, 4: true, 6: true },
  maxFilesPerRequest: 10,
  maxUploadMb: 25,
  maxBatchMb: 80,
  maxCaptionLen: 40,
  rateLimitPerMin: 30,
  retentionMaxFiles: 800,
  slideIntervalMs: 5000,
  maxLiveSlides: 40,
};

function loadConfig() {
  const raw = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
  return {
    ...DEFAULTS,
    ...raw,
    filters: { ...DEFAULTS.filters, ...(raw.filters || {}) },
    layouts: { ...DEFAULTS.layouts, ...(raw.layouts || {}) },
  };
}
let config = loadConfig();

for (const d of [UPLOADS, TMP, ASSETS, QR_DIR]) fs.mkdirSync(d, { recursive: true });

const app = express();
const server = http.createServer(app);
function isAllowedOrigin(origin) {
  if (!origin) return true;
  return /^https:\/\/[a-z0-9-]+\.github\.io$/i.test(origin)
    || /^https:\/\/[a-z0-9-]+\.trycloudflare\.com$/i.test(origin)
    || /^http:\/\/(?:localhost|127\.0\.0\.1|192\.168\.1\.139):3000$/i.test(origin);
}
const corsOptions = {
  origin: (origin, callback) => callback(null, isAllowedOrigin(origin)),
  methods: ['GET', 'HEAD', 'POST', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'Authorization'],
  exposedHeaders: ['Retry-After'],
  maxAge: 86400,
};
const io = new Server(server, {
  cors: corsOptions,
  maxHttpBufferSize: 20 * 1024 * 1024,
  pingTimeout: 20000,
});

app.set('trust proxy', true);
app.use(cors(corsOptions));
app.use('/api', (req, res, next) => {
  res.set('Cache-Control', 'no-store');
  next();
});
app.use(express.json({ limit: '60mb' }));

/* ---------- Proxy-aware in-memory rate limiter ---------- */
const rateLimits = new Map();
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
  const hits = (rateLimits.get(key) || []).filter((t) => t > windowStart);
  hits.push(now);
  rateLimits.set(key, hits);
  if (hits.length > limit) {
    res.set('Retry-After', '60');
    return res.status(429).json({ error: 'Too many uploads — please wait a minute and try again' });
  }
  next();
}
setInterval(() => {
  const windowStart = Date.now() - 60_000;
  for (const [key, hits] of rateLimits) {
    const activeHits = hits.filter((time) => time > windowStart);
    if (activeHits.length) rateLimits.set(key, activeHits);
    else rateLimits.delete(key);
  }
}, 5 * 60 * 1000).unref();

/* ---------- Static ---------- */
app.use('/uploads', express.static(UPLOADS, {
  setHeaders: (res) => res.setHeader('Cache-Control', 'public, max-age=31536000, immutable'),
}));
app.use('/qr', express.static(QR_DIR, {
  setHeaders: (res) => res.setHeader('Cache-Control', 'no-store'),
}));
app.use(express.static(path.join(ROOT, 'public')));

/* ---------- API ---------- */
app.get('/api/health', (req, res) => {
  res.json({ ok: true, uptime: process.uptime() });
});

app.get('/api/config', (req, res) => {
  const { eventTitle, filters, idleResumeMs, attractIdleMs, layouts, maxCaptionLen, slideIntervalMs, maxLiveSlides } = loadConfig();
  let activeUrl = '';
  let qrBaseUrl = '';
  try { activeUrl = fs.readFileSync(path.join(QR_DIR, 'active-url.txt'), 'utf8').trim(); } catch {}
  try { qrBaseUrl = fs.readFileSync(path.join(QR_DIR, 'qr-base-url.txt'), 'utf8').trim(); } catch {}
  const publicUrl = /^https?:\/\/[^\s]+$/.test(activeUrl) ? activeUrl : '';
  if (!/^https:\/\/[a-z0-9.-]+\/[a-z0-9-]+$/i.test(qrBaseUrl)) qrBaseUrl = publicUrl;
  res.json({
    eventTitle, filters, idleResumeMs, attractIdleMs, layouts, maxCaptionLen,
    slideIntervalMs, maxLiveSlides, publicUrl, qrBaseUrl, pagesBaseUrl: PAGES_BASE_URL,
  });
});

app.get('/api/photos', async (req, res) => {
  try {
    const files = (await fsp.readdir(UPLOADS))
      .filter((name) => /\.(jpe?g|png|webp)$/i.test(name));
    const entries = await Promise.all(files.map(async (name) => {
      try {
        const stat = await fsp.stat(path.join(UPLOADS, name));
        if (!stat.isFile()) return null;
        const meta = await sharp(path.join(UPLOADS, name)).metadata().catch(() => ({}));
        return {
          url: `/uploads/${name}`,
          name,
          mtime: stat.mtimeMs,
          w: meta.width || 1200,
          h: meta.height || 1600,
        };
      } catch {
        return null;
      }
    }));
    res.json(entries.filter(Boolean).sort((a, b) => b.mtime - a.mtime).slice(0, 400));
  } catch (error) {
    console.error('photo listing failed:', error);
    res.status(500).json({ error: 'Could not list photos.' });
  }
});

/* ---------- Upload: general candids ---------- */
const upload = multer({
  storage: multer.diskStorage({
    destination: (req, file, cb) => cb(null, TMP),
    filename: (req, file, cb) => cb(null, `${Date.now()}-${crypto.randomBytes(4).toString('hex')}`),
  }),
  limits: {
    files: config.maxFilesPerRequest || 10,
    fileSize: 50 * 1024 * 1024,
  },
  fileFilter: (req, file, cb) => cb(null, /^image\//i.test(file.mimetype || '')),
});

app.post('/api/upload-general', rateLimit, (req, res) => {
  const maxFiles = config.maxFilesPerRequest || 10;
  upload.array('photos', maxFiles)(req, res, async (err) => {
    if (err) {
      await Promise.all((req.files || []).map((file) => fsp.unlink(file.path).catch(() => {})));
      const code = err.code === 'LIMIT_FILE_SIZE' ? 413 : 400;
      return res.status(code).json({ error: err.message });
    }
    if (!req.files || !req.files.length) {
      return res.status(400).json({ error: 'No image files received' });
    }
    if (req.files.reduce((n, f) => n + f.size, 0) > (config.maxBatchMb || 80) * 1024 * 1024) {
      await Promise.all(req.files.map((file) => fsp.unlink(file.path).catch(() => {})));
      return res.status(413).json({ error: 'Batch too large — upload in smaller groups' });
    }
    const files = req.files;
    const perFileLimit = (config.maxUploadMb || 25) * 1024 * 1024;
    const skipped = [];
    const saved = [];
    const uploaded = [];
    for (const f of files) {
      try {
        if (!/^image\/(jpeg|jpg|png|webp)$/i.test(f.mimetype || '')
            || f.size > perFileLimit) {
          skipped.push(f.originalname);
          continue;
        }
        const filename = `candid-${Date.now()}-${crypto.randomBytes(3).toString('hex')}.jpg`;
        const info = await sharp(f.path, { limitInputPixels: 40000000, failOn: 'none' })
          .rotate()
          .resize(1200, 1920, { fit: 'cover', position: sharp.strategy.attention })
          .toColourspace('srgb')
          .jpeg({ quality: 88 })
          .toFile(path.join(UPLOADS, filename));
        const url = `/uploads/${filename}`;
        saved.push(url);
        uploaded.push(f.originalname);
        io.emit('new-photo', { url, name: filename, w: info.width, h: info.height, type: 'candid' });
      } catch {
        skipped.push(f.originalname);
      } finally {
        await fsp.unlink(f.path).catch(() => {});
      }
    }
    return res.json({ ok: saved.length > 0, saved, uploaded, skipped });
  });
});

/* ---------- Upload: photo booth composites ---------- */
const CELLS = {
  '1': [{ left: 70, top: 250, width: 1060, height: 1420 }],
  '2': [
    { left: 70, top: 250, width: 1060, height: 700 },
    { left: 70, top: 970, width: 1060, height: 700 },
  ],
  '4': [
    { left: 70, top: 250, width: 520, height: 700 },
    { left: 610, top: 250, width: 520, height: 700 },
    { left: 70, top: 970, width: 520, height: 700 },
    { left: 610, top: 970, width: 520, height: 700 },
  ],
  '6': [
    { left: 70, top: 250, width: 520, height: 460 },
    { left: 610, top: 250, width: 520, height: 460 },
    { left: 70, top: 730, width: 520, height: 460 },
    { left: 610, top: 730, width: 520, height: 460 },
    { left: 70, top: 1210, width: 520, height: 460 },
    { left: 610, top: 1210, width: 520, height: 460 },
  ],
};

app.post('/api/upload-booth', rateLimit, async (req, res) => {
  try {
    config = loadConfig();
    const { images, layout, filter, caption: rawCaption } = req.body || {};
    const layoutKey = String(layout);
    if (!config.layouts[layoutKey] || !CELLS[layoutKey]) {
      return res.status(400).json({ error: `Layout ${layoutKey} is not enabled` });
    }
    const caption = typeof req.body?.caption === 'string'
      ? rawCaption.trim().replace(/[&<>'"]/g, '').slice(0, config.maxCaptionLen || 40)
      : '';
    if (!config.filters[filter] || !['color', 'bw'].includes(filter)) {
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
      const dataUrl = typeof images[i] === 'string' ? images[i] : '';
      const separator = dataUrl.indexOf(',');
      if (separator < 0 || !/^data:image\/[a-zA-Z0-9.+-]+;base64$/.test(dataUrl.slice(0, separator))) {
        return res.status(400).json({ error: `Invalid image data for frame ${i + 1}` });
      }
      try {
        const buf = Buffer.from(dataUrl.slice(separator + 1), 'base64');
        if (!buf.length) throw new Error('Empty frame');
        let pipe = sharp(buf, { limitInputPixels: 40000000, failOn: 'none' })
          .rotate()
          .resize(cell.width, cell.height, { fit: 'cover', position: sharp.strategy.attention })
          .toColourspace('srgb');
        if (filter === 'bw') {
          pipe = pipe.grayscale().modulate({ brightness: 1.03, contrast: 1.15 });
        }
        composites.push({
          input: await pipe.png().toBuffer(),
          left: cell.left,
          top: cell.top,
        });
      } catch {
        return res.status(400).json({ error: `Could not process frame ${i + 1}` });
      }
    }

    const baseWithCells = await sharp({
      create: {
        width: 1200, height: 1920, channels: 4,
        background: { r: 250, g: 246, b: 240, alpha: 1 }, // #FAF6F0
      },
    }).composite(composites).png().toBuffer();

    await ensureFrame();

    const overlays = [{ input: FRAME, left: 0, top: 0 }];
    if (caption) {
      const captionSvg = Buffer.from(
        `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="90">` +
        `<rect x="0" y="0" width="1200" height="90" fill="#FAF6F0"/>` +
        `<text x="600" y="55" text-anchor="middle" dominant-baseline="middle" ` +
        `font-family="Liberation Serif, DejaVu Serif, serif" font-size="34" ` +
        `font-weight="bold" font-style="italic" fill="#1B4332">${caption}</text></svg>`
      );
      overlays.push({ input: captionSvg, left: 0, top: 1790 });
    }

    const filename = `booth-${Date.now()}-${crypto.randomBytes(3).toString('hex')}.jpg`;
    await sharp(baseWithCells)
      .composite(overlays)
      .jpeg({ quality: 92 })
      .toFile(path.join(UPLOADS, filename));

    const url = `/uploads/${filename}`;
    io.emit('new-photo', { url, name: filename, w: 1200, h: 1920, type: 'booth' });
    return res.json({ ok: true, url });
  } catch (e) {
    console.error('upload-booth failed:', e);
    return res.status(500).json({ error: 'Could not process those photos — please try again' });
  }
});

const REACTIONS = new Set(['❤️', '😂', '🎄', '🎅', '✨', '🥳', '👏', '🎉', '😍', '🤶']);
app.post('/api/react', rateLimit, (req, res) => {
  const emoji = typeof req.body?.emoji === 'string' ? req.body.emoji : '';
  if (!REACTIONS.has(emoji)) return res.status(400).json({ error: 'Choose one of the available reactions.' });
  io.emit('reaction', { emoji });
  res.json({ ok: true });
});

/* ---------- Retention ---------- */
function pruneRetention() {
  if (io.engine.clientsCount > 0) return;
  try {
    const max = loadConfig().retentionMaxFiles || 800;
    const files = fs.readdirSync(UPLOADS)
      .filter((f) => /\.(jpe?g|png|webp)$/i.test(f))
      .map((f) => ({ f, mtime: fs.statSync(path.join(UPLOADS, f)).mtimeMs }))
      .sort((a, b) => a.mtime - b.mtime); // oldest first
    if (files.length <= max) return;
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
  await ensureFrame();
  for (const name of await fsp.readdir(TMP)) {
    await fsp.unlink(path.join(TMP, name)).catch((error) => {
      console.error(`temporary upload cleanup failed for ${name}:`, error);
    });
  }
  pruneRetention();
  setInterval(pruneRetention, 60 * 60 * 1000).unref();

  const PORT = process.env.PORT || 3000;
  server.listen(PORT, () => console.log(`party-gallery listening on :${PORT}`));
})().catch((error) => {
  console.error('Party Gallery startup failed:', error);
  process.exitCode = 1;
});
