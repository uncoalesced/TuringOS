// ui-shell — Electron main process.
// Reads ClaudeOS state from ~/.claudeos and the machine, and pushes one
// snapshot to the page whenever something changes. The page never touches
// the system directly.

const { app, BrowserWindow, ipcMain, nativeTheme } = require('electron');
const { execFile } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const DATA_DIR = path.join(os.homedir(), '.claudeos');
const STATE_FILE = path.join(DATA_DIR, 'state.json');
const KIOSK = process.env.KIOSK === '1';
const POLL_MS = 2000;

let win = null;

// ─── Readers ────────────────────────────────────────────────────────────────

function readJSON(file) {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    return null;
  }
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(Number(pid), 0);
    return true;
  } catch {
    return false;
  }
}

function readBattery() {
  if (process.platform !== 'linux') return null;
  const base = '/sys/class/power_supply';
  try {
    const bat = fs.readdirSync(base).find((n) => n.startsWith('BAT'));
    if (!bat) return null;
    const level = Number(fs.readFileSync(path.join(base, bat, 'capacity'), 'utf8'));
    const status = fs.readFileSync(path.join(base, bat, 'status'), 'utf8').trim();
    return { level, charging: status === 'Charging' || status === 'Full' };
  } catch {
    return null;
  }
}

let wifi = null;
function refreshWifi() {
  if (process.platform !== 'linux') return;
  execFile('nmcli', ['-t', '-f', 'ACTIVE,SSID', 'dev', 'wifi'], { timeout: 3000 }, (err, out) => {
    if (err) return;
    const line = out.split('\n').find((l) => l.startsWith('yes:'));
    wifi = line ? { ssid: line.slice(4) } : { ssid: null };
  });
}

let lastCpu = os.cpus();
function readCpu() {
  const now = os.cpus();
  let idle = 0;
  let total = 0;
  now.forEach((c, i) => {
    const prev = lastCpu[i]?.times ?? c.times;
    for (const k of Object.keys(c.times)) total += c.times[k] - prev[k];
    idle += c.times.idle - prev.idle;
  });
  lastCpu = now;
  return total > 0 ? Math.round(100 * (1 - idle / total)) : 0;
}

function snapshot() {
  const state = readJSON(STATE_FILE);
  return {
    // "live" means ClaudeOS has been initialised on this machine.
    live: fs.existsSync(DATA_DIR),
    agent: {
      running: pidAlive(state?.agent_pid),
      task: state?.agent_task || null,
    },
    sandbox: state?.active_sandbox ? path.basename(state.active_sandbox) : null,
    gameMode: state?.game_mode === 'on',
    system: {
      host: os.hostname(),
      cpu: readCpu(),
      mem: Math.round(100 * (1 - os.freemem() / os.totalmem())),
      battery: readBattery(),
      wifi,
    },
  };
}

// ─── Push loop ──────────────────────────────────────────────────────────────

function push() {
  if (win && !win.isDestroyed()) win.webContents.send('state', snapshot());
}

let watcher = null;
let debounce = null;
function watchData() {
  if (watcher || !fs.existsSync(DATA_DIR)) return;
  try {
    watcher = fs.watch(DATA_DIR, () => {
      clearTimeout(debounce);
      debounce = setTimeout(push, 80);
    });
    watcher.on('error', () => {
      watcher = null;
    });
  } catch {
    watcher = null;
  }
}

// ─── Window ─────────────────────────────────────────────────────────────────

function createWindow() {
  win = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 960,
    minHeight: 600,
    frame: false,
    kiosk: KIOSK,
    fullscreen: KIOSK,
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#262624' : '#F4F3EE',
    title: 'ui-shell',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  win.loadFile(path.join(__dirname, 'index.html'));

  // Frameless and kiosk windows have no close button, so Ctrl/⌘+Q always quits.
  win.webContents.on('before-input-event', (e, input) => {
    if (input.type === 'keyDown' && (input.control || input.meta) && input.key.toLowerCase() === 'q') {
      e.preventDefault();
      app.quit();
    }
  });

  // Dev only: UI_SHELL_SHOT=/path/out.png captures the window after it settles.
  if (process.env.UI_SHELL_SHOT) {
    win.webContents.once('did-finish-load', () => {
      setTimeout(async () => {
        const img = await win.webContents.capturePage();
        fs.writeFileSync(process.env.UI_SHELL_SHOT, img.toPNG());
        if (process.env.UI_SHELL_SHOT_QUIT === '1') app.quit();
      }, 1200);
    });
  }
  win.on('closed', () => {
    win = null;
  });
}

ipcMain.handle('state:get', () => snapshot());

app.whenReady().then(() => {
  createWindow();
  refreshWifi();
  watchData();
  setInterval(() => {
    watchData();
    push();
  }, POLL_MS);
  setInterval(refreshWifi, 10000);
});

app.on('window-all-closed', () => app.quit());
