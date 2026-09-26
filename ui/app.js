// ui-shell — renderer. Draws whatever snapshot main.js sends.
// Opened in a plain browser (no Electron), it falls back to sample data.

const $ = (sel) => document.querySelector(sel);
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

const SAMPLE = {
  live: false,
  agent: { running: true, task: 'Refactor the auth module and run the tests' },
  sandbox: 'task-1727340000',
  gameMode: false,
  system: { host: 'claudeos', cpu: 18, mem: 42, battery: { level: 82, charging: false }, wifi: { ssid: 'Studio' } },
};

// ─── Clock ──────────────────────────────────────────────────────────────────

function greeting(hour) {
  if (hour < 5) return 'Working late.';
  if (hour < 12) return 'Good morning.';
  if (hour < 18) return 'Good afternoon.';
  return 'Good evening.';
}

function tickClock() {
  const now = new Date();
  const time = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
  const shortDate = now.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });
  const longDate = now.toLocaleDateString([], { weekday: 'long', day: 'numeric', month: 'long' });

  $('#menubar-clock').textContent = `${shortDate}  ${time}`;
  $('#hero-time').textContent = time;
  $('#hero-date').textContent = longDate;
  $('#hero-greeting').textContent = greeting(now.getHours());
}

// ─── State ──────────────────────────────────────────────────────────────────

function setTile(id, value, sub, tone) {
  const tile = $(id);
  tile.querySelector('.tile-value').textContent = value;
  tile.querySelector('.tile-sub').textContent = sub;
  if (tone) tile.dataset.tone = tone;
  else delete tile.dataset.tone;
}

function render(snap) {
  // Before ClaudeOS is initialised, keep real system numbers but show
  // sample agent data so the desktop still reads as intended.
  const s = snap.live ? snap : { ...SAMPLE, system: { ...SAMPLE.system, ...pickDefined(snap.system) } };
  $('#sample-badge').hidden = snap.live;

  const status = $('#agent-status');
  status.dataset.state = s.agent.running ? 'working' : 'idle';
  status.querySelector('.status-label').textContent = s.agent.running ? 'Working' : 'Idle';

  const sandboxChip = $('#chip-sandbox');
  sandboxChip.hidden = !s.sandbox;
  sandboxChip.querySelector('.chip-label').textContent = s.sandbox || '';
  $('#chip-game').hidden = !s.gameMode;

  const { battery, wifi, cpu, mem, host } = s.system;
  $('#battery').hidden = !battery;
  if (battery) {
    $('.battery-fill').setAttribute('width', (11.6 * battery.level) / 100);
    $('.battery-label').textContent = `${battery.level}%`;
    $('#battery').title = battery.charging ? 'Charging' : 'Battery';
  }
  $('#wifi').hidden = !wifi;
  if (wifi) $('#wifi').title = wifi.ssid ? `Wi-Fi: ${wifi.ssid}` : 'Wi-Fi: not connected';

  setTile('#tile-agent',
    s.agent.running ? 'Working' : 'Idle',
    s.agent.task || 'Waiting for a task',
    s.agent.running ? 'accent' : null);
  setTile('#tile-sandbox',
    s.sandbox ? 'Active' : 'None',
    s.sandbox ? 'Original project protected' : 'No agent changes pending');
  setTile('#tile-game',
    s.gameMode ? 'On' : 'Off',
    s.gameMode ? 'Claude runs in the background' : 'Normal priorities',
    s.gameMode ? 'accent' : null);
  setTile('#tile-system',
    `${cpu}% CPU`,
    `${mem}% memory · ${host}`);
}

function pickDefined(obj) {
  return Object.fromEntries(Object.entries(obj || {}).filter(([, v]) => v != null));
}

// ─── Theme ──────────────────────────────────────────────────────────────────

function setTheme(next, x, y) {
  const root = document.documentElement;
  const apply = () => {
    root.dataset.theme = next;
  };
  if (!document.startViewTransition || reducedMotion.matches) return apply();

  // Percentages, not pixels: on HiDPI screens Chromium can resolve pixel
  // clip-paths on the snapshot in device pixels, which moves the circle.
  // A circle's % radius is relative to hypot(w, h) / √2.
  const w = innerWidth;
  const h = innerHeight;
  const r = Math.hypot(Math.max(x, w - x), Math.max(y, h - y));
  root.style.setProperty('--reveal-x', `${(100 * x) / w}%`);
  root.style.setProperty('--reveal-y', `${(100 * y) / h}%`);
  root.style.setProperty('--reveal-r', `${(100 * r) / (Math.hypot(w, h) / Math.SQRT2)}%`);
  root.classList.add('theme-switching');
  document.startViewTransition(apply).finished.finally(() => root.classList.remove('theme-switching'));
}

$('#theme-toggle').addEventListener('click', (e) => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  localStorage.setItem('theme', next);
  const box = e.currentTarget.getBoundingClientRect();
  setTheme(next, box.left + box.width / 2, box.top + box.height / 2);
});

// Follow the system until the user picks a theme themselves.
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
  if (!localStorage.getItem('theme')) setTheme(e.matches ? 'dark' : 'light', innerWidth, 0);
});

// ─── Boot ───────────────────────────────────────────────────────────────────

tickClock();
setInterval(tickClock, 1000);

if (window.shell) {
  window.shell.getState().then(render);
  window.shell.onState(render);
} else {
  render(SAMPLE);
}
