const express = require('express');
const session = require('express-session');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const os = require('os');

const app = express();
const PORT = process.env.PORT || 3000;
const VAULT_DIR = path.join(__dirname, 'vault');
const LOGS_FILE = path.join(__dirname, 'logs.json');
const NOTES_FILE = path.join(__dirname, 'notes.json');
const ADMIN_PASSWORD = process.env.ADMIN_PASS || 'KyleVault2026';

if (!fs.existsSync(VAULT_DIR)) fs.mkdirSync(VAULT_DIR, { recursive: true });
if (!fs.existsSync(NOTES_FILE)) fs.writeFileSync(NOTES_FILE, '[]');

function readJson(file, fallback = []) {
  try {
    if (fs.existsSync(file)) return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (e) {}
  return fallback;
}

function writeJson(file, data) {
  try {
    fs.writeFileSync(file, JSON.stringify(data, null, 2));
  } catch (e) {}
}

function parseDevice(userAgent) {
  if (!userAgent) return 'Unknown Device';
  if (/android/i.test(userAgent)) {
    const match = userAgent.match(/\b(SM-[A-Za-z0-9]+|Redmi\s?[A-Za-z0-9]+|POCO\s?[A-Za-z0-9]+|RMX[0-9]+|Pixel\s?[0-9a-zA-Z]+|V[0-9]+[A-Za-z]+|CPH[0-9]+)\b/i);
    return match ? `Android (${match[1]})` : 'Android Device';
  }
  if (/iphone|ipad|ipod/i.test(userAgent)) return 'Apple iOS';
  if (/windows/i.test(userAgent)) return 'Windows PC';
  if (/macintosh|mac os x/i.test(userAgent)) return 'macOS';
  if (/linux/i.test(userAgent)) return 'Linux';
  return 'Web Client';
}

function logActivity(type, name, description, req) {
  const logs = readJson(LOGS_FILE, []);
  logs.unshift({
    timestamp: new Date().toLocaleString(),
    type,
    name: name || 'Guest',
    description,
    device: parseDevice(req ? req.headers['user-agent'] : '')
  });
  if (logs.length > 200) logs.pop();
  writeJson(LOGS_FILE, logs);
}

app.use(express.json({ limit: '10gb' }));
app.use(express.urlencoded({ extended: true, limit: '10gb' }));

app.use(session({
  secret: 'cyber-vault-hub-secret-2026',
  resave: false,
  saveUninitialized: false,
  cookie: { maxAge: 86400000 }
}));

function requireAdmin(req, res, next) {
  if (req.session && req.session.isAdmin) return next();
  res.status(401).json({ error: 'Admin access required' });
}

function getSafePath(targetRelPath = '') {
  const clean = String(targetRelPath).replace(/^(\.\.(\/|\\|$))+/, '');
  const full = path.normalize(path.join(VAULT_DIR, clean));
  if (!full.startsWith(VAULT_DIR)) return null;
  return full;
}

const storage = multer.diskStorage({
  destination: (req, file, cb) => {
    const safePath = getSafePath(req.body.folder || '');
    if (!safePath) return cb(new Error('Invalid path'), null);
    cb(null, safePath);
  },
  filename: (req, file, cb) => {
    cb(null, `${Date.now()}-${file.originalname.replace(/[^a-zA-Z0-9._-]/g, '_')}`);
  }
});

const upload = multer({ storage, limits: { fileSize: Infinity } });

app.use('/vault-raw', express.static(VAULT_DIR));
app.use(express.static(path.join(__dirname, 'public')));

app.post('/api/clear-visitor', (req, res) => {
  if (req.session) req.session.visitorName = null;
  res.json({ success: true });
});

app.post('/api/log-visit', (req, res) => {
  const visitorName = (req.body.name || '').trim();
  if (!visitorName) return res.status(400).json({ error: 'Name required' });
  req.session.visitorName = visitorName;
  logActivity('Visit', visitorName, 'Entered CyberVault Hub', req);
  res.json({ success: true });
});

app.post('/api/login', (req, res) => {
  if (req.body.password === ADMIN_PASSWORD) {
    req.session.isAdmin = true;
    logActivity('Auth', 'Admin', 'Admin logged in', req);
    return res.json({ success: true });
  }
  logActivity('Alert', 'Unknown', 'Failed admin login attempt', req);
  res.status(401).json({ success: false });
});

app.post('/api/logout', (req, res) => {
  logActivity('Auth', 'Admin', 'Admin logged out', req);
  req.session.destroy(() => res.json({ success: true }));
});

app.get('/api/auth-status', (req, res) => {
  res.json({
    isAdmin: !!(req.session && req.session.isAdmin),
    visitorName: (req.session && req.session.visitorName) || null
  });
});

app.get('/api/telemetry', (req, res) => {
  const totalMem = os.totalmem();
  const freeMem = os.freemem();
  res.json({
    platform: `${os.platform()} (${os.arch()})`,
    uptimeSec: Math.floor(process.uptime()),
    ramUsedMB: Math.round((totalMem - freeMem) / 1048576),
    ramTotalMB: Math.round(totalMem / 1048576),
    noteCount: readJson(NOTES_FILE, []).length
  });
});

app.get('/api/logs', requireAdmin, (req, res) => {
  res.json(readJson(LOGS_FILE, []));
});

// Notes / Dropboard API
app.get('/api/notes', (req, res) => {
  res.json(readJson(NOTES_FILE, []));
});

app.post('/api/notes', (req, res) => {
  const title = (req.body.title || 'Untitled Drop').trim().slice(0, 80);
  const content = (req.body.content || '').trim().slice(0, 5000);
  const tag = (req.body.tag || 'General').trim().slice(0, 24);
  if (!content) return res.status(400).json({ error: 'Content cannot be empty' });

  const author = (req.session && req.session.visitorName) || (req.session && req.session.isAdmin ? 'Admin' : 'Guest');
  const notes = readJson(NOTES_FILE, []);
  notes.unshift({
    id: String(Date.now()),
    title,
    content,
    tag,
    author,
    createdAt: new Date().toLocaleString()
  });
  if (notes.length > 100) notes.pop();
  writeJson(NOTES_FILE, notes);
  logActivity('Note', author, `Posted drop: ${title}`, req);
  res.json({ success: true });
});

app.delete('/api/notes/:id', requireAdmin, (req, res) => {
  const notes = readJson(NOTES_FILE, []).filter((n) => n.id !== req.params.id);
  writeJson(NOTES_FILE, notes);
  logActivity('Delete', 'Admin', `Removed drop #${req.params.id}`, req);
  res.json({ success: true });
});

// Vault Files API
app.get('/api/download', (req, res) => {
  const relPath = req.query.path || '';
  const safePath = getSafePath(relPath);
  if (!safePath || !fs.existsSync(safePath)) return res.status(404).send('Not found');
  const visitor = (req.session && req.session.visitorName) || 'Guest';
  logActivity('Download', visitor, `Downloaded ${path.basename(safePath)}`, req);
  res.download(safePath);
});

app.get('/api/files', async (req, res) => {
  try {
    const relFolder = req.query.folder || '';
    const safePath = getSafePath(relFolder);
    if (!safePath || !fs.existsSync(safePath)) return res.status(400).json({ error: 'Invalid folder' });
    const entries = await fs.promises.readdir(safePath, { withFileTypes: true });
    const items = entries.map((entry) => {
      const itemRelPath = path.join(relFolder, entry.name).replace(/\\/g, '/');
      const ext = path.extname(entry.name).toLowerCase();
      let type = 'file';
      if (entry.isDirectory()) type = 'folder';
      else if (['.jpg', '.jpeg', '.png', '.gif', '.webp', '.svg', '.avif'].includes(ext)) type = 'image';
      else if (['.mp4', '.webm', '.mkv', '.mov', '.avi', '.m4v'].includes(ext)) type = 'video';
      else if (['.mp3', '.wav', '.ogg', '.flac'].includes(ext)) type = 'audio';
      return {
        name: entry.name,
        type,
        relPath: itemRelPath,
        url: `/vault-raw/${itemRelPath.split('/').map(encodeURIComponent).join('/')}`
      };
    });
    res.json({ folder: relFolder, items });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/mkdir', requireAdmin, async (req, res) => {
  try {
    const safeName = String(req.body.name || '').replace(/[^a-zA-Z0-9._-]/g, '_');
    if (!safeName) return res.status(400).json({ error: 'Invalid folder name' });
    const safePath = getSafePath(path.join(req.body.folder || '', safeName));
    if (!safePath) return res.status(400).json({ error: 'Invalid path' });
    await fs.promises.mkdir(safePath, { recursive: true });
    logActivity('Folder', 'Admin', `Created folder: ${safeName}`, req);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/upload', requireAdmin, upload.array('files'), (req, res) => {
  logActivity('Upload', 'Admin', `Uploaded ${req.files ? req.files.length : 0} file(s)`, req);
  res.json({ success: true });
});

app.post('/api/delete', requireAdmin, async (req, res) => {
  try {
    const relPath = req.body.path || '';
    const safePath = getSafePath(relPath);
    if (!safePath || safePath === VAULT_DIR) return res.status(400).json({ error: 'Invalid path' });
    const stats = await fs.promises.stat(safePath);
    if (stats.isDirectory()) await fs.promises.rm(safePath, { recursive: true, force: true });
    else await fs.promises.unlink(safePath);
    logActivity('Delete', 'Admin', `Deleted: ${relPath}`, req);
    res.json({ success: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

const server = app.listen(PORT, '0.0.0.0', () => {
  console.log(`CyberVault Hub running on port ${PORT}`);
});
server.timeout = 0;
server.keepAliveTimeout = 0;
