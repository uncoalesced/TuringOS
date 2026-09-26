// ui-shell — Electron main process.
// Reads ClaudeOS state from ~/.claudeos and the machine, and pushes one
// snapshot to the page whenever something changes. The page never touches
// the system directly.

const { app, BrowserWindow, ipcMain, nativeTheme } = require('electron');
const { execFile, execFileSync, spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const DATA_DIR = path.join(os.homedir(), '.claudeos');
const STATE_FILE = path.join(DATA_DIR, 'state.json');
const KIOSK = process.env.KIOSK === '1';
const POLL_MS = 2000;
const REPO_ROOT = path.join(__dirname, '..');
const CLAUDEOS_BIN = path.join(REPO_ROOT, 'claudeos');

let win = null;

// Run the theme reveal's clip-path animation on the compositor, off the main thread.
app.commandLine.appendSwitch('enable-features', 'CompositeClipPathAnimation');

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

// First name for the greeting: the account's full name, else the login name.
function readFirstName() {
  let full = '';
  try {
    if (process.platform === 'darwin') {
      full = execFileSync('id', ['-F'], { encoding: 'utf8' }).trim();
    } else {
      const line = fs.readFileSync('/etc/passwd', 'utf8').split('\n')
        .find((l) => l.startsWith(`${os.userInfo().username}:`));
      full = (line?.split(':')[4] || '').split(',')[0];
    }
  } catch {}
  const name = (full || os.userInfo().username).split(/\s+/)[0];
  return name ? name[0].toUpperCase() + name.slice(1) : null;
}
const USER_NAME = readFirstName();

// ─── Projects (for the @ picker) ────────────────────────────────────────────
// Git repos under $HOME and next to this repo, 3 levels deep. Override with
// CLAUDEOS_PROJECT_ROOTS=/path/a:/path/b.

const SKIP_DIRS = new Set(['node_modules', 'Library', 'Applications', 'Movies', 'Music', 'Pictures', 'snap', 'go', 'vendor', 'target', 'build', 'dist']);
// On a Mac preview, reading these pops a privacy prompt; the VM has no such prompts.
if (process.platform === 'darwin') ['Desktop', 'Documents', 'Downloads'].forEach((d) => SKIP_DIRS.add(d));

async function findProjects() {
  const roots = process.env.CLAUDEOS_PROJECT_ROOTS
    ? process.env.CLAUDEOS_PROJECT_ROOTS.split(':')
    : [os.homedir(), path.dirname(REPO_ROOT)];
  const found = new Map();

  async function walk(dir, depth) {
    if (found.size >= 200) return;
    let entries;
    try {
      entries = await fs.promises.readdir(dir, { withFileTypes: true });
    } catch {
      return;
    }
    if (entries.some((e) => e.name === '.git')) {
      found.set(dir, { name: path.basename(dir), path: dir });
      return;
    }
    if (depth === 0) return;
    await Promise.all(entries
      .filter((e) => e.isDirectory() && !e.name.startsWith('.') && !SKIP_DIRS.has(e.name))
      .map((e) => walk(path.join(dir, e.name), depth - 1)));
  }

  await Promise.all([...new Set(roots)].map((r) => walk(r, 3)));
  return [...found.values()].sort((a, b) => a.name.localeCompare(b.name));
}

// ─── Weather ────────────────────────────────────────────────────────────────
// Location from the public IP (ipapi.co, fallback ipwho.is), weather from
// Open-Meteo. No API keys. Override with CLAUDEOS_WEATHER="lat,lon,City",
// or turn it off with CLAUDEOS_WEATHER=off.

const WEATHER_MS = 15 * 60 * 1000;
let weather = null;
let place = null;

async function getJSON(url) {
  const res = await fetch(url, { signal: AbortSignal.timeout(6000) });
  if (!res.ok) throw new Error(`${res.status} ${url}`);
  return res.json();
}

async function locate() {
  const env = process.env.CLAUDEOS_WEATHER;
  if (env && env !== 'off') {
    const [lat, lon, ...city] = env.split(',');
    return { lat: Number(lat), lon: Number(lon), city: city.join(',').trim() || null };
  }
  try {
    const j = await getJSON('https://ipapi.co/json/');
    if (j.latitude) return { lat: j.latitude, lon: j.longitude, city: j.city };
  } catch {}
  const j = await getJSON('https://ipwho.is/');
  return { lat: j.latitude, lon: j.longitude, city: j.city };
}

async function refreshWeather() {
  if (process.env.CLAUDEOS_WEATHER === 'off') return;
  try {
    place ??= await locate();
    const q = new URLSearchParams({
      latitude: place.lat,
      longitude: place.lon,
      current: 'temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_direction_10m,is_day',
      timezone: 'auto',
    });
    const { current: c } = await getJSON(`https://api.open-meteo.com/v1/forecast?${q}`);
    weather = {
      city: place.city,
      temp: Math.round(c.temperature_2m),
      feels: Math.round(c.apparent_temperature),
      rain: c.precipitation,
      wind: Math.round(c.wind_speed_10m),
      windDir: c.wind_direction_10m,
      code: c.weather_code,
      day: c.is_day === 1,
    };
    push();
  } catch {
    // Offline or blocked: keep the last reading, or none.
  }
}

function snapshot() {
  const state = readJSON(STATE_FILE);
  return {
    // "live" means ClaudeOS has been initialised on this machine.
    live: fs.existsSync(DATA_DIR),
    user: { name: USER_NAME },
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
    weather,
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
    title: 'HushOS',
    icon: path.join(__dirname, 'assets/brand/app-icon.png'),
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

  // Dev only: reload the page whenever the renderer files change, so edits
  // show up in the open window without a manual relaunch. On by default;
  // off in KIOSK mode (the real demo) or with NO_WATCH=1. Only covers the
  // renderer (html/css/js) — main.js/preload.js need a real restart, since
  // that code is already loaded into this process.
  if (!KIOSK && process.env.NO_WATCH !== '1') {
    const RELOAD_FILES = new Set(['index.html', 'styles.css', 'app.js', 'theme.js']);
    let reloadTimer = null;
    fs.watch(__dirname, (_event, filename) => {
      if (!filename || !RELOAD_FILES.has(filename)) return;
      clearTimeout(reloadTimer);
      reloadTimer = setTimeout(() => {
        if (win && !win.isDestroyed()) win.webContents.reload();
      }, 120);
    });
  }

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

// ─── Dock ───────────────────────────────────────────────────────────────────
// Fixed, curated set for now (not auto-discovered from installed .desktop
// files). Each entry lists real system commands to try in order, so it works
// across whatever's actually installed on the VM.

const DOCK_APPS = {
  terminal: { label: 'Terminal', commands: [['x-terminal-emulator', []], ['xterm', []], ['konsole', []]] },
  files: {
    label: 'Files',
    commands: [
      ['xdg-open', [os.homedir()]],
      ['dolphin', [os.homedir()]],
      ['nautilus', [os.homedir()]],
      ['pcmanfm', [os.homedir()]],
      ['nemo', [os.homedir()]],
      ['thunar', [os.homedir()]],
    ],
  },
  browser: { label: 'Browser', commands: [['xdg-open', ['https://']], ['x-www-browser', []]] },
  settings: { label: 'Settings', commands: [['systemsettings', []], ['systemsettings5', []]] },
};

function commandExists(cmd) {
  try {
    execFileSync('command', ['-v', cmd], { shell: '/bin/bash' });
    return true;
  } catch {
    return false;
  }
}

ipcMain.handle('dock:launch', (_e, id) => {
  const app_ = DOCK_APPS[id];
  if (!app_) return { ok: false, error: `Unknown dock app: ${id}` };
  const found = app_.commands.find(([cmd]) => commandExists(cmd));
  if (!found) return { ok: false, error: `${app_.label} isn't installed on this machine.` };
  const [cmd, args] = found;
  try {
    const child = spawn(cmd, args, { detached: true, stdio: 'ignore' });
    child.unref();
    return { ok: true };
  } catch (err) {
    return { ok: false, error: `Couldn't start ${app_.label}: ${err.message}` };
  }
});

ipcMain.handle('state:get', () => snapshot());
ipcMain.handle('projects:list', () => findProjects());

// Start the agent on a task. The UI never builds shell strings: arguments go
// straight to the claudeos script, which creates the sandbox first.
ipcMain.handle('agent:start', (_e, { project, task }) => {
  if (!fs.existsSync(DATA_DIR)) return { ok: false, error: 'HushOS is not set up. Run ./claudeos init first.' };
  if (typeof project !== 'string' || !fs.existsSync(project)) return { ok: false, error: 'That project folder no longer exists.' };
  if (typeof task !== 'string' || !task.trim()) return { ok: false, error: 'Describe the task first.' };
  const child = spawn(CLAUDEOS_BIN, ['agent', 'start', project, task.trim()], {
    cwd: REPO_ROOT,
    detached: true,
    stdio: 'ignore',
  });
  child.unref();
  return { ok: true };
});

app.whenReady().then(() => {
  if (process.platform === 'darwin') app.dock?.setIcon(path.join(__dirname, 'assets/brand/app-icon.png'));
  createWindow();
  refreshWifi();
  refreshWeather();
  setInterval(refreshWeather, WEATHER_MS);
  watchData();
  setInterval(() => {
    watchData();
    push();
  }, POLL_MS);
  setInterval(refreshWifi, 10000);
});

app.on('window-all-closed', () => app.quit());
