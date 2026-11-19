#!/usr/bin/env bash
set -e

cd "$(dirname "$0")"

R='\033[1;31m'
G='\033[1;32m'
Y='\033[1;33m'
M='\033[1;35m'
C='\033[1;36m'
W='\033[1;37m'
D='\033[0;90m'
NC='\033[0m'

check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

ensure_deps() {
    if ! check_cmd node; then
        echo -e "${Y}[*] Installing Node.js & network tools...${NC}"
        pkg update -y && pkg install -y nodejs net-tools zip
    fi
    if ! check_cmd zip; then
        pkg install -y zip
    fi
    if [ ! -f "package.json" ]; then
        npm init -y >/dev/null 2>&1
    fi
    if [ ! -d "node_modules/localtunnel" ] || [ ! -d "node_modules/express" ]; then
        echo -e "${Y}[*] Installing Node modules (express, express-session, multer, localtunnel)...${NC}"
        npm install express express-session multer localtunnel --no-audit --no-fund
    fi

    # Fix openurl crash on Android/Termux
    OPENURL_JS="node_modules/openurl/openurl.js"
    if [ -f "$OPENURL_JS" ]; then
        if grep -q "Unsupported platform" "$OPENURL_JS"; then
            echo -e "${Y}[*] Patching openurl for Android compatibility...${NC}"
            sed -i "s/throw new Error('Unsupported platform: ' + process.platform);/console.log('Skipping browser open on Android'); return;/g" "$OPENURL_JS"
        fi
    fi
}

setup_files() {
    mkdir -p vault public

    cat << 'SERVE_EOF' > server.js
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
SERVE_EOF

    cat << 'HTML_EOF' > public/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
  <title>CYBERVAULT // Cloud Drop &amp; Media Node</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600;700&family=Space+Grotesk:wght@500;700&display=swap');
    body { font-family: 'Space Grotesk', sans-serif; background: #050810; color: #e2e8f0; }
    code, pre, .mono { font-family: 'JetBrains Mono', monospace; }
    .cyber-panel { background: rgba(13, 19, 34, 0.82); backdrop-filter: blur(14px); border: 1px solid rgba(56, 189, 248, 0.18); }
    .cyber-card { background: rgba(17, 25, 44, 0.72); border: 1px solid rgba(148, 163, 184, 0.14); transition: all 0.2s ease; }
    .cyber-card:hover { border-color: rgba(56, 189, 248, 0.45); transform: translateY(-2px); }
    .tab-active { background: linear-gradient(135deg, #06b6d4, #6366f1); color: #040812; font-weight: 700; }
  </style>
</head>
<body class="min-h-screen selection:bg-cyan-400 selection:text-slate-950">

  <!-- Top Navigation -->
  <header class="cyber-panel sticky top-0 z-40 border-b border-cyan-500/20">
    <div class="max-w-6xl mx-auto px-4 py-3 flex flex-wrap items-center justify-between gap-3">
      <div class="flex items-center gap-3">
        <div class="w-9 h-9 rounded-xl bg-gradient-to-br from-cyan-400 to-indigo-600 flex items-center justify-center text-slate-950 font-extrabold shadow-lg shadow-cyan-500/25">
          ◈
        </div>
        <div>
          <h1 class="text-base sm:text-lg font-bold tracking-wide text-white">CYBERVAULT <span class="text-cyan-400 text-xs mono">v2.6</span></h1>
          <p id="telemetryLine" class="text-[11px] text-slate-400 mono">Connecting to node telemetry...</p>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <button id="logsBtn" onclick="openLogsModal()" class="hidden bg-slate-900 hover:bg-slate-800 border border-cyan-500/30 text-cyan-300 px-3 py-1.5 rounded-lg text-xs font-bold">
          📡 Logs
        </button>
        <button id="authBtn" onclick="openLoginModal()" class="bg-cyan-500 hover:bg-cyan-400 text-slate-950 px-3.5 py-1.5 rounded-lg text-xs font-bold transition">
          Admin Login
        </button>
      </div>
    </div>
  </header>

  <main class="max-w-6xl mx-auto px-4 py-6">
    <!-- Navigation Tabs -->
    <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
      <div class="inline-flex p-1 rounded-xl bg-slate-900/90 border border-slate-800 gap-1">
        <button id="tabVaultBtn" onclick="switchTab('vault')" class="px-4 py-2 rounded-lg text-xs tab-active transition">
          🗂️ Media &amp; File Vault
        </button>
        <button id="tabDropBtn" onclick="switchTab('drop')" class="px-4 py-2 rounded-lg text-xs text-slate-300 hover:text-white transition">
          📝 Live Dropboard &amp; Snippets
        </button>
      </div>

      <input type="search" id="searchInput" oninput="handleSearch()" placeholder="Filter files or notes..." class="bg-slate-900/90 border border-slate-800 rounded-xl px-3.5 py-2 text-xs text-slate-200 w-full sm:w-64 focus:outline-none focus:border-cyan-400" />
    </div>

    <!-- Admin Controls -->
    <section id="adminBox" class="hidden cyber-panel rounded-2xl p-4 sm:p-5 mb-6">
      <div class="text-xs font-bold uppercase tracking-wider text-cyan-400 mb-3">⚡ Root Node Controls</div>
      <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
        <form id="uploadForm" class="bg-slate-950/70 p-3 rounded-xl border border-slate-800 flex flex-col sm:flex-row gap-2">
          <input type="file" id="fileInput" multiple class="text-xs text-slate-400 file:mr-2 file:py-1 file:px-3 file:rounded-lg file:border-0 file:bg-cyan-500 file:text-slate-950 file:font-bold cursor-pointer w-full" />
          <button type="submit" id="uploadBtn" class="bg-cyan-500 hover:bg-cyan-400 text-slate-950 px-4 py-2 rounded-lg text-xs font-bold shrink-0">Upload</button>
        </form>
        <form id="mkdirForm" class="bg-slate-950/70 p-3 rounded-xl border border-slate-800 flex flex-col sm:flex-row gap-2">
          <input type="text" id="folderNameInput" placeholder="Create directory..." class="bg-slate-900 border border-slate-800 rounded-lg px-3 py-2 text-xs text-slate-200 w-full focus:outline-none focus:border-cyan-400" />
          <button type="submit" class="bg-slate-800 hover:bg-slate-700 text-white px-4 py-2 rounded-lg text-xs font-bold shrink-0">New Folder</button>
        </form>
      </div>
    </section>

    <!-- TAB 1: VAULT -->
    <section id="vaultSection">
      <div id="breadcrumbs" class="cyber-panel rounded-xl px-4 py-2.5 mb-5 text-xs flex items-center gap-1.5 overflow-x-auto"></div>
      <div id="vaultGrid" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4 gap-4"></div>
    </section>

    <!-- TAB 2: DROPBOARD -->
    <section id="dropSection" class="hidden">
      <form id="noteForm" class="cyber-panel rounded-2xl p-4 sm:p-5 mb-6 space-y-3">
        <div class="text-xs font-bold uppercase tracking-wider text-indigo-400">📡 Broadcast Text / Code Snippet</div>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <input type="text" id="noteTitle" placeholder="Title (e.g. Server IP, Script, Note)" class="sm:col-span-2 bg-slate-950 border border-slate-800 rounded-xl px-3.5 py-2 text-xs text-slate-200 focus:outline-none focus:border-cyan-400" required />
          <select id="noteTag" class="bg-slate-950 border border-slate-800 rounded-xl px-3 py-2 text-xs text-slate-200 focus:outline-none focus:border-cyan-400">
            <option value="General">Tag: General</option>
            <option value="Code">Tag: Code / Shell</option>
            <option value="Link">Tag: Link / Config</option>
            <option value="Pinned">Tag: Important</option>
          </select>
        </div>
        <textarea id="noteContent" rows="3" placeholder="Paste text, commands, or notes to share across devices on this network..." class="w-full bg-slate-950 border border-slate-800 rounded-xl p-3 text-xs text-slate-200 mono focus:outline-none focus:border-cyan-400" required></textarea>
        <div class="flex justify-end">
          <button type="submit" class="bg-gradient-to-r from-cyan-500 to-indigo-500 text-slate-950 px-5 py-2 rounded-xl text-xs font-bold">Post to Dropboard</button>
        </div>
      </form>

      <div id="notesGrid" class="grid grid-cols-1 md:grid-cols-2 gap-4"></div>
    </section>
  </main>

  <!-- Visitor Modal -->
  <div id="visitorModal" class="fixed inset-0 bg-black/85 backdrop-blur-md flex items-center justify-center p-4 z-50">
    <div class="cyber-panel p-6 rounded-2xl max-w-sm w-full border border-cyan-500/30 shadow-2xl">
      <h2 class="text-base font-bold text-white mb-1">Identify Terminal Session</h2>
      <p class="text-xs text-slate-400 mb-4">Enter a display name or handle to enter the node.</p>
      <input type="text" id="visitorNameInput" placeholder="e.g. Kyle / Guest-01" class="w-full bg-slate-950 border border-slate-800 rounded-xl px-3.5 py-2.5 text-xs text-white mb-4 focus:outline-none focus:border-cyan-400" />
      <button onclick="submitVisitor()" class="w-full bg-cyan-500 hover:bg-cyan-400 text-slate-950 py-2.5 rounded-xl text-xs font-bold">Connect</button>
    </div>
  </div>

  <!-- Admin Login Modal -->
  <div id="loginModal" class="fixed inset-0 bg-black/80 backdrop-blur-md flex items-center justify-center p-4 hidden z-50">
    <div class="cyber-panel p-6 rounded-2xl max-w-sm w-full">
      <h3 class="text-base font-bold text-white mb-3">🔐 Admin Authentication</h3>
      <input type="password" id="passwordInput" placeholder="Enter Admin Password" class="w-full bg-slate-950 border border-slate-800 rounded-xl px-3.5 py-2.5 text-xs text-white mb-4 focus:outline-none focus:border-cyan-400" />
      <div class="flex justify-end gap-2">
        <button onclick="closeLoginModal()" class="px-4 py-2 text-xs text-slate-400">Cancel</button>
        <button onclick="submitLogin()" class="bg-cyan-500 text-slate-950 px-4 py-2 rounded-xl text-xs font-bold">Unlock</button>
      </div>
    </div>
  </div>

  <!-- Activity Logs Modal -->
  <div id="logsModal" class="fixed inset-0 bg-black/80 backdrop-blur-md flex items-center justify-center p-4 hidden z-50">
    <div class="cyber-panel p-5 rounded-2xl max-w-4xl w-full max-h-[85vh] flex flex-col">
      <div class="flex justify-between items-center pb-3 mb-3 border-b border-slate-800">
        <h3 class="text-sm font-bold text-cyan-400">📡 Live Node Telemetry &amp; Access Logs</h3>
        <button onclick="closeLogsModal()" class="text-slate-400 hover:text-white text-sm font-bold">✕</button>
      </div>
      <div class="overflow-y-auto flex-1 rounded-xl border border-slate-800 bg-slate-950/90">
        <table class="w-full text-left text-xs">
          <thead class="bg-slate-900 text-cyan-300 text-[10px] uppercase sticky top-0">
            <tr><th class="p-2.5">Time</th><th class="p-2.5">User</th><th class="p-2.5">Device</th><th class="p-2.5">Type</th><th class="p-2.5">Event</th></tr>
          </thead>
          <tbody id="logsBody"></tbody>
        </table>
      </div>
    </div>
  </div>

  <!-- Fullscreen Preview Modal -->
  <div id="previewModal" class="fixed inset-0 bg-black/95 flex items-center justify-center p-4 hidden z-50" onclick="closePreview()">
    <button onclick="closePreview()" class="absolute top-4 right-4 bg-slate-800 text-white rounded-full px-3 py-1.5 text-xs font-bold">✕ Close</button>
    <div id="previewContent" class="max-w-full max-h-full flex items-center justify-center" onclick="event.stopPropagation()"></div>
  </div>

  <script>
    let currentFolder = '';
    let isAdmin = false;
    let cachedFiles = [];
    let cachedNotes = [];
    let activeTab = 'vault';

    function switchTab(tab) {
      activeTab = tab;
      document.getElementById('vaultSection').classList.toggle('hidden', tab !== 'vault');
      document.getElementById('dropSection').classList.toggle('hidden', tab !== 'drop');
      document.getElementById('tabVaultBtn').className = tab === 'vault' ? 'px-4 py-2 rounded-lg text-xs tab-active transition' : 'px-4 py-2 rounded-lg text-xs text-slate-300 hover:text-white transition';
      document.getElementById('tabDropBtn').className = tab === 'drop' ? 'px-4 py-2 rounded-lg text-xs tab-active transition' : 'px-4 py-2 rounded-lg text-xs text-slate-300 hover:text-white transition';
      if (tab === 'drop') loadNotes();
    }

    async function refreshTelemetry() {
      try {
        const res = await fetch('/api/telemetry');
        const t = await res.json();
        document.getElementById('telemetryLine').textContent = `${t.platform} • RAM ${t.ramUsedMB}/${t.ramTotalMB}MB • Uptime ${t.uptimeSec}s`;
      } catch (e) {}
    }

    async function checkAuth() {
      if (!sessionStorage.getItem('cv_session')) {
        await fetch('/api/clear-visitor', { method: 'POST' });
      }
      const res = await fetch('/api/auth-status');
      const data = await res.json();
      isAdmin = data.isAdmin;

      document.getElementById('adminBox').classList.toggle('hidden', !isAdmin);
      document.getElementById('logsBtn').classList.toggle('hidden', !isAdmin);
      const authBtn = document.getElementById('authBtn');
      authBtn.textContent = isAdmin ? 'Logout' : 'Admin Login';
      authBtn.onclick = isAdmin ? logout : openLoginModal;

      if (!data.visitorName) {
        document.getElementById('visitorModal').classList.remove('hidden');
      } else {
        document.getElementById('visitorModal').classList.add('hidden');
        loadFiles(currentFolder);
        loadNotes();
      }
    }

    async function submitVisitor() {
      const name = document.getElementById('visitorNameInput').value.trim();
      if (!name) return alert('Enter a display name.');
      const res = await fetch('/api/log-visit', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ name })
      });
      if (res.ok) {
        sessionStorage.setItem('cv_session', '1');
        document.getElementById('visitorModal').classList.add('hidden');
        loadFiles(currentFolder);
        loadNotes();
      }
    }

    function openLoginModal() { document.getElementById('loginModal').classList.remove('hidden'); }
    function closeLoginModal() { document.getElementById('loginModal').classList.add('hidden'); }

    async function submitLogin() {
      const password = document.getElementById('passwordInput').value;
      const res = await fetch('/api/login', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ password })
      });
      if (res.ok) {
        document.getElementById('passwordInput').value = '';
        closeLoginModal();
        checkAuth();
      } else {
        alert('Invalid admin password.');
      }
    }

    async function logout() {
      await fetch('/api/logout', { method: 'POST' });
      checkAuth();
    }

    async function openLogsModal() {
      document.getElementById('logsModal').classList.remove('hidden');
      const res = await fetch('/api/logs');
      if (!res.ok) return;
      const logs = await res.json();
      document.getElementById('logsBody').innerHTML = logs.map((l) => `
        <tr class="border-b border-slate-800/70">
          <td class="p-2.5 text-slate-400 whitespace-nowrap">${l.timestamp}</td>
          <td class="p-2.5 font-bold text-cyan-300">${l.name}</td>
          <td class="p-2.5 mono text-slate-300">${l.device}</td>
          <td class="p-2.5 font-bold text-indigo-400">${l.type}</td>
          <td class="p-2.5 text-slate-300">${l.description}</td>
        </tr>
      `).join('') || '<tr><td colspan="5" class="p-4 text-center text-slate-500">No logs recorded yet.</td></tr>';
    }
    function closeLogsModal() { document.getElementById('logsModal').classList.add('hidden'); }

    function renderBreadcrumbs() {
      const parts = currentFolder.split('/').filter(Boolean);
      let html = `<button onclick="loadFiles('')" class="text-cyan-400 font-bold hover:underline">/vault</button>`;
      let acc = '';
      for (const p of parts) {
        acc = acc ? `${acc}/${p}` : p;
        html += `<span class="text-slate-600">/</span><button onclick="loadFiles('${acc}')" class="text-cyan-400 font-bold hover:underline">${p}</button>`;
      }
      document.getElementById('breadcrumbs').innerHTML = html;
    }

    async function loadFiles(folder = '') {
      currentFolder = folder;
      renderBreadcrumbs();
      const res = await fetch(`/api/files?folder=${encodeURIComponent(folder)}`);
      const data = await res.json();
      cachedFiles = data.items || [];
      renderFiles();
    }

    function renderFiles() {
      const q = document.getElementById('searchInput').value.trim().toLowerCase();
      const items = q ? cachedFiles.filter((i) => i.name.toLowerCase().includes(q)) : cachedFiles;
      const grid = document.getElementById('vaultGrid');
      grid.innerHTML = '';
      if (!items.length) {
        grid.innerHTML = `<div class="col-span-full text-center py-14 text-slate-500 text-xs">No files found in this directory.</div>`;
        return;
      }
      for (const item of items) {
        const card = document.createElement('div');
        card.className = 'cyber-card rounded-2xl p-3.5 flex flex-col justify-between gap-3';
        const dlUrl = `/api/download?path=${encodeURIComponent(item.relPath)}`;
        const delBtn = isAdmin ? `<button onclick="deleteItem('${item.relPath}')" class="w-full bg-rose-600/80 hover:bg-rose-600 text-white py-1.5 rounded-xl text-xs font-bold">Delete</button>` : '';

        if (item.type === 'folder') {
          card.innerHTML = `<div onclick="loadFiles('${item.relPath}')" class="cursor-pointer flex items-center gap-3 py-2"><span class="text-2xl">📁</span><span class="text-xs font-bold text-white truncate">${item.name}</span></div>${delBtn}`;
        } else if (item.type === 'image') {
          card.innerHTML = `<img src="${item.url}" loading="lazy" onclick="openPreview('${item.url}','image')" class="w-full h-36 object-cover rounded-xl bg-slate-950 cursor-pointer" /><div class="text-xs font-semibold truncate">${item.name}</div><div class="space-y-1.5"><a href="${dlUrl}" class="block text-center bg-slate-800 hover:bg-cyan-500 hover:text-slate-950 py-1.5 rounded-xl text-xs font-bold transition">Download</a>${delBtn}</div>`;
        } else if (item.type === 'video') {
          card.innerHTML = `<video src="${item.url}" preload="metadata" onclick="openPreview('${item.url}','video')" class="w-full h-36 object-cover rounded-xl bg-black cursor-pointer"></video><div class="text-xs font-semibold truncate">${item.name}</div><div class="space-y-1.5"><a href="${dlUrl}" class="block text-center bg-slate-800 hover:bg-cyan-500 hover:text-slate-950 py-1.5 rounded-xl text-xs font-bold transition">Download</a>${delBtn}</div>`;
        } else {
          card.innerHTML = `<div class="flex items-center gap-2.5 py-2"><span class="text-2xl">📄</span><span class="text-xs font-semibold truncate">${item.name}</span></div><div class="space-y-1.5"><a href="${dlUrl}" class="block text-center bg-slate-800 hover:bg-cyan-500 hover:text-slate-950 py-1.5 rounded-xl text-xs font-bold transition">Download</a>${delBtn}</div>`;
        }
        grid.appendChild(card);
      }
    }

    async function loadNotes() {
      const res = await fetch('/api/notes');
      cachedNotes = await res.json();
      renderNotes();
    }

    function renderNotes() {
      const q = document.getElementById('searchInput').value.trim().toLowerCase();
      const list = q ? cachedNotes.filter((n) => n.title.toLowerCase().includes(q) || n.content.toLowerCase().includes(q)) : cachedNotes;
      const grid = document.getElementById('notesGrid');
      grid.innerHTML = '';
      if (!list.length) {
        grid.innerHTML = `<div class="col-span-full text-center py-12 text-slate-500 text-xs">No notes posted yet.</div>`;
        return;
      }
      for (const n of list) {
        const card = document.createElement('div');
        card.className = 'cyber-card rounded-2xl p-4 flex flex-col justify-between gap-3';
        const delBtn = isAdmin ? `<button onclick="deleteNote('${n.id}')" class="text-rose-400 hover:text-rose-300 text-xs font-bold">Delete</button>` : '';
        card.innerHTML = `
          <div>
            <div class="flex items-center justify-between gap-2 mb-2">
              <span class="px-2.5 py-0.5 rounded-full text-[10px] font-bold bg-cyan-500/15 text-cyan-300 border border-cyan-500/30">${n.tag}</span>
              <span class="text-[10px] text-slate-400">${n.createdAt}</span>
            </div>
            <h3 class="text-sm font-bold text-white mb-2">${n.title}</h3>
            <pre class="bg-slate-950/90 border border-slate-800 rounded-xl p-3 text-xs text-slate-300 overflow-x-auto whitespace-pre-wrap break-words">${n.content.replace(/</g, '&lt;')}</pre>
          </div>
          <div class="flex items-center justify-between text-[11px] text-slate-400 pt-2 border-t border-slate-800/80">
            <span>By <strong class="text-slate-200">${n.author}</strong></span>
            <div class="flex items-center gap-3">
              <button onclick="copyNoteText(this)" data-text="${encodeURIComponent(n.content)}" class="text-cyan-400 hover:underline font-bold">Copy</button>
              ${delBtn}
            </div>
          </div>`;
        grid.appendChild(card);
      }
    }

    function copyNoteText(btn) {
      navigator.clipboard.writeText(decodeURIComponent(btn.dataset.text));
      btn.textContent = 'Copied!';
      setTimeout(() => { btn.textContent = 'Copy'; }, 1500);
    }

    function handleSearch() {
      if (activeTab === 'vault') renderFiles();
      else renderNotes();
    }

    function openPreview(url, type) {
      const box = document.getElementById('previewContent');
      box.innerHTML = type === 'video'
        ? `<video src="${url}" controls autoplay playsinline class="max-h-[82vh] max-w-full rounded-2xl"></video>`
        : `<img src="${url}" class="max-h-[82vh] max-w-full rounded-2xl" />`;
      document.getElementById('previewModal').classList.remove('hidden');
    }
    function closePreview() {
      document.getElementById('previewModal').classList.add('hidden');
      document.getElementById('previewContent').innerHTML = '';
    }

    async function deleteItem(relPath) {
      if (!confirm(`Delete "${relPath}"?`)) return;
      const res = await fetch('/api/delete', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ path: relPath })
      });
      if (res.ok) loadFiles(currentFolder);
    }

    async function deleteNote(id) {
      if (!confirm('Delete this drop?')) return;
      const res = await fetch(`/api/notes/${id}`, { method: 'DELETE' });
      if (res.ok) loadNotes();
    }

    document.getElementById('uploadForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const input = document.getElementById('fileInput');
      if (!input.files.length) return alert('Choose files first.');
      const btn = document.getElementById('uploadBtn');
      btn.disabled = true; btn.textContent = 'Uploading...';
      const fd = new FormData();
      for (const f of input.files) fd.append('files', f);
      fd.append('folder', currentFolder);
      try {
        const res = await fetch('/api/upload', { method: 'POST', body: fd });
        if (res.ok) { input.value = ''; loadFiles(currentFolder); }
      } finally {
        btn.disabled = false; btn.textContent = 'Upload';
      }
    });

    document.getElementById('mkdirForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const input = document.getElementById('folderNameInput');
      const name = input.value.trim();
      if (!name) return;
      const res = await fetch('/api/mkdir', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ folder: currentFolder, name })
      });
      if (res.ok) { input.value = ''; loadFiles(currentFolder); }
    });

    document.getElementById('noteForm').addEventListener('submit', async (e) => {
      e.preventDefault();
      const title = document.getElementById('noteTitle').value;
      const tag = document.getElementById('noteTag').value;
      const content = document.getElementById('noteContent').value;
      const res = await fetch('/api/notes', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ title, tag, content })
      });
      if (res.ok) {
        document.getElementById('noteTitle').value = '';
        document.getElementById('noteContent').value = '';
        loadNotes();
      }
    });

    checkAuth();
    refreshTelemetry();
    setInterval(refreshTelemetry, 5000);
  </script>
</body>
</html>
HTML_EOF
}

export_project_zip() {
    local out_dir="/sdcard/Download"
    [ -d "$out_dir" ] || out_dir="$HOME/storage/downloads"
    mkdir -p "$out_dir"
    local zip_target="$out_dir/CyberVaultHub.zip"
    (cd .. && zip -r "$zip_target" "$(basename "$PWD")" -x "*/node_modules/*" >/dev/null 2>&1) && \
        echo -e "\n${G}✔ Project ZIP saved to: ${C}$zip_target${NC}" || \
        echo -e "\n${Y}[!] Could not write to Download folder. Run 'termux-setup-storage' first.${NC}"
}

is_server_running() {
    pgrep -f "node server.js" >/dev/null 2>&1
}

start_website_server() {
    ensure_deps
    setup_files
    if is_server_running; then
        echo -e "\n${Y}[!] CyberVault Hub is ALREADY running.${NC}"
    else
        echo -e "\n${G}[+] Starting CyberVault Hub server...${NC}"
        nohup node server.js > server.log 2>&1 &
        sleep 1
        if is_server_running; then
            echo -e "${G}✔ Server running in background!${NC}"
            IP=$(ifconfig 2>/dev/null | grep -E 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d':' -f2 | head -n 1)
            echo -e " 📱 Local URL : ${C}http://localhost:3000${NC}"
            [ -n "$IP" ] && echo -e " 🌐 LAN URL   : ${C}http://$IP:3000${NC}"
        else
            echo -e "${R}✘ Failed to start. Check server.log${NC}"
        fi
    fi
}

stop_website_server() {
    if is_server_running; then
        pkill -f "node server.js" || true
        sleep 1
        echo -e "\n${G}✔ Server stopped.${NC}"
    else
        echo -e "\n${Y}[!] Server is not running.${NC}"
    fi
}

restart_website_server() {
    stop_website_server
    sleep 1
    start_website_server
}

setup_tunnel() {
    ensure_deps
    echo -e "\n${M}==================================================${NC}"
    echo -e "${M}        Launching LocalTunnel Public URL          ${NC}"
    echo -e "${M}==================================================${NC}"
    npx localtunnel --port 3000
}

show_sys_info() {
    local file_count=$(find vault -type f 2>/dev/null | wc -l)
    echo -e "\n${C}┌── CyberVault Node Diagnostics ────────────────┐${NC}"
    echo -e " ${W}OS Host         :${NC} ${G}$(uname -o)${NC}"
    echo -e " ${W}Kernel          :${NC} ${G}$(uname -r)${NC}"
    echo -e " ${W}Architecture    :${NC} ${G}$(uname -m)${NC}"
    echo -e " ${W}Vault Files     :${NC} ${Y}${file_count} file(s)${NC}"
    echo -e " ${W}Directory       :${NC} ${Y}$(pwd)${NC}"
    echo -e "${C}└───────────────────────────────────────────────┘${NC}"
}

show_menu() {
    clear
    local file_count=$(find vault -type f 2>/dev/null | wc -l)
    local status="${R}OFFLINE🔴${NC}"
    if is_server_running; then
        status="${G}ONLINE🟢 (Port 3000)${NC}"
    fi

    echo -e "${C}==================================================${NC}"
    echo -e "${M}           CYBERVAULT HUB CONTROL CENTER          ${NC}"
    echo -e "${C}==================================================${NC}"
    echo -e " ${W}Server Status    :${NC} ${status}"
    echo -e " ${W}Vault Storage    :${NC} ${G}${file_count} file(s) in ~/CyberVaultHub/vault${NC}"
    echo -e " ${W}Default Admin    :${NC} ${Y}KyleVault2026${NC}"
    echo -e "${C}==================================================${NC}"
    echo -e "  ${G}[1]${NC} ${Y}🚀 Start Website Server${NC}"
    echo -e "  ${G}[2]${NC} ${R}🛑 Stop Website Server${NC}"
    echo -e "  ${G}[3]${NC} ${C}🔄 Restart Website Server${NC}"
    echo -e "  ${G}[4]${NC} ${W}🌐 Expose Public Link (LocalTunnel)${NC}"
    echo -e "  ${G}[5]${NC} ${W}📦 Export Project ZIP to Download Folder${NC}"
    echo -e "  ${G}[6]${NC} ${W}📊 Display Node Diagnostics${NC}"
    echo -e "  ${R}[0]${NC} ${W}Exit Menu${NC}"
    echo -e "${D}--------------------------------------------------${NC}"
}

main() {
    ensure_deps
    setup_files
    export_project_zip
    while true; do
        show_menu
        echo -ne " ${C}Select Option [0-6]:${NC} "
        read -r choice
        case "$choice" in
            1) start_website_server ;;
            2) stop_website_server ;;
            3) restart_website_server ;;
            4) setup_tunnel ;;
            5) export_project_zip ;;
            6) show_sys_info ;;
            0) exit 0 ;;
            *) echo -e " ${R}Invalid option [0-6].${NC}" ;;
        esac
        echo ""
        read -rp " Press [Enter] to return to menu..."
    done
}

main
