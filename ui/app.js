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
  weather: { city: 'Bengaluru', temp: 26, feels: 30, rain: 0, wind: 8, windDir: 200, code: 2, day: true },
  user: { name: null },
};

const SAMPLE_PROJECTS = [
  { name: 'claudeos', path: '~/code/claudeos' },
  { name: 'auth-service', path: '~/code/auth-service' },
  { name: 'dotfiles', path: '~/dotfiles' },
];

let lastSnap = null;
let userName = null;
let pendingStart = false;
let pendingStartTimer = null;

// ─── Weather ────────────────────────────────────────────────────────────────
// WMO weather codes (Open-Meteo): https://open-meteo.com/en/docs

function wxIcon(code, day) {
  if (code === 0) return day ? 'wx-sun' : 'wx-moon';
  if (code <= 2) return day ? 'wx-partly' : 'wx-partly-night';
  if (code === 3) return 'wx-cloud';
  if (code <= 48) return 'wx-fog';
  if (code <= 67 || (code >= 80 && code <= 82)) return 'wx-rain';
  if (code <= 77 || (code >= 85 && code <= 86)) return 'wx-snow';
  if (code >= 95) return 'wx-storm';
  return 'wx-cloud';
}

function wxLabel(code) {
  const table = {
    0: 'Clear', 1: 'Mostly clear', 2: 'Partly cloudy', 3: 'Cloudy',
    45: 'Foggy', 48: 'Foggy',
    51: 'Light drizzle', 53: 'Drizzle', 55: 'Heavy drizzle',
    61: 'Light rain', 63: 'Rain', 65: 'Heavy rain',
    71: 'Light snow', 73: 'Snow', 75: 'Heavy snow',
    80: 'Rain showers', 81: 'Rain showers', 82: 'Violent showers',
    95: 'Thunderstorm', 96: 'Thunderstorm', 99: 'Thunderstorm',
  };
  return table[code] || 'Weather';
}

function renderWeather(w) {
  const btn = $('#weather');
  btn.hidden = !w;
  if (!w) return;
  const icon = wxIcon(w.code, w.day);
  document.querySelectorAll('.wx-use').forEach((u) => u.setAttribute('href', `#${icon}`));
  $('.weather-temp').textContent = `${w.temp}°`;
  $('.weather-city').textContent = w.city || '';
  $('.wc-title').textContent = w.city ? `${w.city} Weather` : 'Weather';
  $('.wc-cond').textContent = wxLabel(w.code);
  $('.wc-temp').textContent = `${w.temp}°`;
  $('.wc-feels').textContent = `${w.feels}°`;
  $('.wc-rain').textContent = `${w.rain} mm`;
  $('.wc-wind').textContent = `${w.wind} km/h`;
  $('.wc-arrow').style.transform = `rotate(${(w.windDir ?? 0) + 180}deg)`;
}

let weatherOpen = false;
function setWeatherOpen(open) {
  weatherOpen = open;
  const card = $('#weather-card');
  $('#weather').setAttribute('aria-expanded', String(open));
  if (open) {
    card.hidden = false;
    card.classList.remove('is-closing');
  } else if (!card.hidden) {
    card.classList.add('is-closing');
    setTimeout(() => { if (weatherOpen === false) card.hidden = true; }, 150);
  }
}

$('#weather').addEventListener('click', () => setWeatherOpen(!weatherOpen));
document.addEventListener('click', (e) => {
  if (weatherOpen && !e.target.closest('#weather, #weather-card')) setWeatherOpen(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && weatherOpen) setWeatherOpen(false);
});

// ─── Quote of the day ───────────────────────────────────────────────────────
// No backend for this yet: a fixed list, picked deterministically by date so
// it's stable across reloads and doesn't flicker between renders.

const QUOTES = [
  'Life shrinks or expands in proportion with one\u2019s courage.',
  'The only way to do great work is to love what you do.',
  'Simplicity is the ultimate sophistication.',
  'What we think, we become.',
  'The obstacle is the way.',
  'Done is better than perfect.',
];

function dayNumber() {
  return Math.floor(Date.now() / 86400000);
}

// ─── Clock ──────────────────────────────────────────────────────────────────

function greeting(hour) {
  const part = hour < 5 ? 'Good evening' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  return userName ? `${part}, ${userName}.` : `${part}.`;
}

function tickClock() {
  const now = new Date();
  const time = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
  const shortDate = now.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });

  $('#menubar-clock').textContent = `${shortDate}  ${time}`;
  $('#hero-time').textContent = time;
  $('#hero-greeting').textContent = greeting(now.getHours());
}

function tickDay() {
  $('#quote').textContent = `\u201C${QUOTES[dayNumber() % QUOTES.length]}\u201D`;
  // Placeholder: no real focus-session tracking exists yet.
  $('#focused-today').textContent = '0m focused today';
}

// ─── State ──────────────────────────────────────────────────────────────────

function render(snap) {
  // Before ClaudeOS is initialised, keep real system numbers but show
  // sample agent data so the desktop still reads as intended.
  const s = snap.live ? snap : { ...SAMPLE, system: { ...SAMPLE.system, ...pickDefined(snap.system) } };
  $('#sample-badge').hidden = snap.live;
  lastSnap = snap;

  const name = snap.user?.name || null;
  if (name !== userName) {
    userName = name;
    tickClock();
  }

  const { battery, wifi, cpu, mem, host } = s.system;
  $('#battery').hidden = !battery;
  if (battery) {
    $('.battery-fill').setAttribute('width', (11.6 * battery.level) / 100);
    $('.battery-label').textContent = `${battery.level}%`;
    $('#battery').title = battery.charging ? 'Charging' : 'Battery';
  }
  $('#wifi').hidden = !wifi;
  if (wifi) $('#wifi').title = wifi.ssid ? `Wi-Fi: ${wifi.ssid}` : 'Wi-Fi: not connected';

  // Three states: idle (nothing running), working (task just sent, sandbox
  // not confirmed yet — see submit()), agentic (the sandboxed agent is
  // actually running). pendingStart clears itself once agent.running is true.
  if (s.agent.running && pendingStart) {
    pendingStart = false;
    clearTimeout(pendingStartTimer);
  }
  const state = pendingStart ? 'working' : s.agent.running ? 'agentic' : 'idle';
  const label = { idle: 'Agent idle', working: 'Starting…', agentic: 'Agentic' }[state];

  const corner = $('#corner-agent');
  corner.dataset.state = state;
  corner.querySelector('.corner-label').textContent = label;
  $('#corner-task').textContent = s.agent.running && s.agent.task ? s.agent.task : '';
  $('#corner-system').textContent = [
    s.sandbox ? 'Sandbox active' : null,
    s.gameMode ? 'Game mode' : null,
    `${cpu}% CPU`,
    `${mem}% memory`,
  ].filter(Boolean).join('  ·  ');
  $('#corner-system').title = host;
  renderWeather(s.weather);
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

// ─── Composer ───────────────────────────────────────────────────────────────
// Type a task, pick a project with @ (or +), press Enter: the agent starts in
// a sandbox of that project.

const input = $('#composer-input');
const mention = $('#mention');
const hint = $('#composer-hint');
const send = $('#composer-send');
const chip = $('#composer-project');
const HINT_HTML = hint.innerHTML;
const folderIcon = chip.querySelector('svg');

let project = null;
let projects = null;
let matches = [];
let active = 0;
let mentionMode = null; // 'typed' (after @) | 'button' (after +) | null
let trigger = null; // { start, end } of the "@query" text being typed
let hintTimer = null;

async function loadProjects({ refresh = false } = {}) {
  if (!window.shell) return SAMPLE_PROJECTS;
  if (!projects || refresh) projects = await window.shell.listProjects();
  return projects;
}

function currentTrigger() {
  const pos = input.selectionStart;
  const m = input.value.slice(0, pos).match(/(^|\s)@([^\s@]*)$/);
  return m ? { start: pos - m[2].length - 1, end: pos, query: m[2] } : null;
}

function shortPath(p) {
  return p.replace(/^\/(Users|home)\/[^/]+/, '~');
}

async function showMention(query) {
  const q = query.toLowerCase();
  const list = await loadProjects();
  matches = list
    .filter((p) => p.name.toLowerCase().includes(q))
    .sort((a, b) => b.name.toLowerCase().startsWith(q) - a.name.toLowerCase().startsWith(q))
    .slice(0, 50);
  active = 0;
  drawMention();
}

function drawMention() {
  if (!mentionMode) return;
  const items = matches.map((p, i) => {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'mention-item';
    el.setAttribute('role', 'option');
    el.setAttribute('aria-selected', String(i === active));
    const name = document.createElement('span');
    name.className = 'mention-name';
    name.textContent = p.name;
    const where = document.createElement('span');
    where.className = 'mention-path';
    where.textContent = `\u200E${shortPath(p.path)}\u200E`; // keep slashes in place under rtl truncation
    el.append(folderIcon.cloneNode(true), name, where);
    el.addEventListener('mousedown', (e) => e.preventDefault());
    el.addEventListener('click', () => pick(p));
    el.addEventListener('mousemove', () => {
      if (active !== i) setActive(i);
    });
    return el;
  });
  if (!items.length) {
    const empty = document.createElement('p');
    empty.className = 'mention-empty';
    empty.textContent = projects && !projects.length ? 'No git projects found in your home folder' : 'No matching projects';
    items.push(empty);
  }
  mention.replaceChildren(...items);
  mention.hidden = false;
  // The list drops down over where the quote sits; hide it rather than
  // let text show through/behind an open picker.
  $('#quote').classList.add('is-hidden');
}

function setActive(i) {
  active = (i + matches.length) % matches.length;
  [...mention.children].forEach((el, j) => el.setAttribute('aria-selected', String(j === active)));
  mention.children[active]?.scrollIntoView({ block: 'nearest' });
}

function closeMention() {
  mentionMode = null;
  trigger = null;
  mention.hidden = true;
  $('#quote').classList.remove('is-hidden');
}

function setProject(p) {
  project = p;
  chip.hidden = !p;
  if (p) {
    chip.querySelector('.composer-project-name').textContent = p.name;
    chip.title = shortPath(p.path);
  }
}

function pick(p) {
  if (trigger) input.setRangeText('', trigger.start, trigger.end, 'end');
  setProject(p);
  closeMention();
  input.focus();
  sync();
}

function setHint(text, tone) {
  clearTimeout(hintTimer);
  hint.textContent = text;
  if (tone) hint.dataset.tone = tone;
  else delete hint.dataset.tone;
  hintTimer = setTimeout(() => {
    hint.innerHTML = HINT_HTML;
    delete hint.dataset.tone;
  }, 4000);
}

function sync() {
  input.style.height = 'auto';
  input.style.height = `${input.scrollHeight}px`;
  send.disabled = !input.value.trim();
}

async function submit() {
  const task = input.value.trim();
  if (!task) return;
  if (!project) {
    setHint('Pick a project with @ first', 'error');
    return;
  }
  if (!window.shell || !lastSnap?.live) {
    setHint('Sample mode: nothing was started', 'error');
    return;
  }
  const res = await window.shell.startAgent(project.path, task);
  if (!res.ok) {
    setHint(res.error, 'error');
    return;
  }
  input.value = '';
  sync();
  setHint(`Started in a sandbox of ${project.name}`);

  // Sandbox creation can take a few seconds before agent_pid shows up in
  // state.json; show "Starting…" right away instead of waiting for the
  // next poll. Give up after 30s so a silent backend failure doesn't leave
  // the corner stuck on "Starting…" forever.
  pendingStart = true;
  if (lastSnap) render(lastSnap);
  clearTimeout(pendingStartTimer);
  pendingStartTimer = setTimeout(() => {
    pendingStart = false;
    if (lastSnap) render(lastSnap);
  }, 30000);
}

input.addEventListener('input', () => {
  sync();
  const t = currentTrigger();
  if (t) {
    mentionMode = 'typed';
    trigger = t;
    showMention(t.query);
  } else if (mentionMode === 'typed') {
    closeMention();
  }
});

input.addEventListener('keydown', (e) => {
  if (mentionMode) {
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      if (matches.length) setActive(active + (e.key === 'ArrowDown' ? 1 : -1));
      return;
    }
    if ((e.key === 'Enter' || e.key === 'Tab') && matches[active]) {
      e.preventDefault();
      pick(matches[active]);
      return;
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      closeMention();
      return;
    }
  }
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    submit();
  } else if (e.key === 'Backspace' && project && input.selectionStart === 0 && input.selectionEnd === 0) {
    setProject(null);
  }
});

input.addEventListener('blur', () => closeMention());

$('#composer-add').addEventListener('mousedown', (e) => e.preventDefault());
$('#composer-add').addEventListener('click', () => {
  if (mentionMode) return closeMention();
  input.focus();
  mentionMode = 'button';
  trigger = null;
  showMention('');
  loadProjects({ refresh: true }).then(() => mentionMode === 'button' && showMention(''));
});

$('#composer-project-clear').addEventListener('click', () => {
  setProject(null);
  input.focus();
});

$('#composer').addEventListener('submit', (e) => {
  e.preventDefault();
  submit();
});

// Ctrl/⌘+K jumps to the composer from anywhere.
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'k') {
    e.preventDefault();
    input.focus();
  }
});

// ─── Boot ───────────────────────────────────────────────────────────────────

tickClock();
setInterval(tickClock, 1000);
tickDay();

if (window.shell) {
  window.shell.getState().then(render);
  window.shell.onState(render);
  loadProjects();
} else {
  render(SAMPLE);
}
