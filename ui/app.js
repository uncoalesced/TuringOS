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
  github: {
    mine: [{ number: 127, title: 'Handle an interrupted pacman install', url: '#' }],
    reviews: [{ number: 89, title: 'Add Btrfs snapshot rollback', repository: { name: 'claudeos' }, url: '#' }],
  },
  // Real personal data, not made up — unlike weather/agent sample data
  // (meant to make the desktop read as intended), a fake meeting here could
  // mislead someone watching a demo who asks if it's real. Always show the
  // honest disconnected state until a real Google account is connected.
  calendar: { connected: false, nextEvent: null },
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

function githubRow(pr, subtext) {
  const a = document.createElement('a');
  a.className = 'widget-row';
  a.href = pr.url;
  a.target = '_blank';
  a.rel = 'noopener';
  const title = document.createElement('span');
  title.className = 'widget-row-title';
  title.textContent = `#${pr.number} ${pr.title}`;
  const sub = document.createElement('span');
  sub.className = 'widget-row-sub';
  sub.textContent = subtext;
  a.append(title, sub);
  return a;
}

function renderGithub(gh) {
  const body = $('#github-body');
  if (!gh) {
    body.replaceChildren();
    const empty = document.createElement('p');
    empty.className = 'widget-empty';
    empty.textContent = "Not connected — run `gh auth login` on this machine.";
    body.append(empty);
    return;
  }
  const rows = [
    ...gh.mine.map((pr) => githubRow(pr, pr.headRefName || 'My PR')),
    ...gh.reviews.map((pr) => githubRow(pr, pr.repository?.name ? `Review · ${pr.repository.name}` : 'Review requested')),
  ];
  body.replaceChildren(...rows.length
    ? rows
    : [Object.assign(document.createElement('p'), { className: 'widget-empty', textContent: 'No open PRs or review requests.' })]);
}

function formatEventTime(iso) {
  if (!iso) return '';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const today = new Date();
  const sameDay = d.toDateString() === today.toDateString();
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return sameDay ? `Today, ${time}` : `${d.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' })}, ${time}`;
}

async function connectGoogle() {
  const btn = $('#calendar-connect');
  if (!window.shell) {
    renderCalendarMessage('Not available in this preview.', true);
    return;
  }
  btn.disabled = true;
  btn.textContent = 'Connecting… check your browser';
  const res = await window.shell.connectGoogle();
  btn.disabled = false;
  btn.textContent = 'Connect Google Calendar';
  if (!res.ok) renderCalendarMessage(res.error, true);
}

function renderCalendarMessage(text, isError) {
  const body = $('#calendar-body');
  const p = document.createElement('p');
  p.className = 'widget-empty';
  if (isError) p.style.color = 'var(--danger)';
  p.textContent = text;
  body.append(p);
}

function renderCalendar(cal) {
  const body = $('#calendar-body');
  body.replaceChildren();
  if (!cal.connected) {
    const empty = document.createElement('p');
    empty.className = 'widget-empty';
    empty.textContent = 'Connect Google Calendar to see your next meeting.';
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.id = 'calendar-connect';
    btn.className = 'widget-connect';
    btn.textContent = 'Connect Google Calendar';
    btn.addEventListener('click', connectGoogle);
    body.append(empty, btn);
    return;
  }
  if (!cal.nextEvent) {
    const empty = document.createElement('p');
    empty.className = 'widget-empty';
    empty.textContent = 'No upcoming events.';
    body.append(empty);
    return;
  }
  const row = document.createElement('div');
  row.className = 'widget-row';
  const title = document.createElement('span');
  title.className = 'widget-row-title';
  title.textContent = cal.nextEvent.title;
  const sub = document.createElement('span');
  sub.className = 'widget-row-sub';
  sub.textContent = formatEventTime(cal.nextEvent.start);
  row.append(title, sub);
  body.append(row);
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

// ─── Side panel ─────────────────────────────────────────────────────────────
// Widgets (Calendar, GitHub) live here. Ctrl/⌘+J or the menu-bar clock opens
// it; it's always in the DOM, just translated off the right edge when shut —
// same reveal mechanic as the dock, not the weather card's hidden-attribute
// dance, since there's no keyframe pop here, just a slide.

let panelOpen = false;
function setPanelOpen(open) {
  panelOpen = open;
  $('#side-panel').classList.toggle('is-visible', open);
}

$('#menubar-clock').addEventListener('click', () => setPanelOpen(!panelOpen));
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'j') {
    e.preventDefault();
    setPanelOpen(!panelOpen);
  }
  if (e.key === 'Escape' && panelOpen) setPanelOpen(false);
});

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
  renderGithub(s.github);
  renderCalendar(s.calendar);
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

// ─── Dock ───────────────────────────────────────────────────────────────────
// Hidden until the cursor hits the bottom edge (mirrors the real macOS dock).
// Icons magnify toward the cursor; transform-origin is the bottom of each
// icon so they grow upward without reflowing their neighbors.

const dock = $('#dock');
const dockItems = [...document.querySelectorAll('.dock-item')];
const dockError = $('#dock-error');

const DOCK_MAX_SCALE = 1.6;
const DOCK_SPREAD = 55; // px — how far the magnification falloff reaches; tight, so the peak is under the cursor and it drops off within a couple of icons, not the whole row
const DOCK_HIDE_DELAY = 250; // ms grace period before hiding, so crossing the gap between edge and dock doesn't flicker it shut

// A real mass-spring-damper per icon, not a CSS transition retargeting a
// JS-computed value. The difference matters here specifically: a transition
// restarts its easing curve from scratch every time the target changes
// (every mousemove), which looks steppy under fast mouse movement — a
// spring integrates continuously, keeps its velocity across target changes,
// and settles the same way whether it's interrupted once or a hundred
// times a second. This is the "spring engine" ui-docs/UI_SHELL.md's Motion
// section describes as not-built-yet; the dock is its first real use.
const DOCK_SPRING_STIFFNESS = 380;
const DOCK_SPRING_DAMPING = 24;
const DOCK_SPRING_EPSILON = 0.001; // close enough to target + slow enough to call it settled

let dockHideTimer = null;
let dockRaf = null;
let dockLastFrameTime = 0;
let pressedDockItem = null;
let dockErrorTimer = null;
let mouseOverDock = false;
let lastMouseX = 0;
const dockScale = dockItems.map(() => 1);
const dockVelocity = dockItems.map(() => 0);

function setDockVisible(visible) {
  clearTimeout(dockHideTimer);
  if (visible) {
    dock.classList.add('is-visible');
    $('#sample-badge').classList.add('is-hidden');
  } else {
    dockHideTimer = setTimeout(() => {
      dock.classList.remove('is-visible');
      resetDockScale();
      $('#sample-badge').classList.remove('is-hidden');
    }, DOCK_HIDE_DELAY);
  }
}

function resetDockScale() {
  if (dockRaf) cancelAnimationFrame(dockRaf);
  dockRaf = null;
  dockLastFrameTime = 0;
  mouseOverDock = false;
  dockItems.forEach((el, i) => {
    dockScale[i] = 1;
    dockVelocity[i] = 0;
    el.style.transform = '';
  });
}

function dockTargetFor(el) {
  if (!mouseOverDock) return 1;
  const box = el.getBoundingClientRect();
  const center = box.left + box.width / 2;
  const dist = Math.abs(lastMouseX - center);
  const falloff = Math.exp(-(dist * dist) / (2 * DOCK_SPREAD * DOCK_SPREAD));
  const scale = 1 + (DOCK_MAX_SCALE - 1) * falloff;
  return el === pressedDockItem ? scale * 0.93 : scale;
}

function stepDockSpring(dtSeconds) {
  let settled = true;
  dockItems.forEach((el, i) => {
    const target = dockTargetFor(el);
    const displacement = dockScale[i] - target;
    const accel = -DOCK_SPRING_STIFFNESS * displacement - DOCK_SPRING_DAMPING * dockVelocity[i];
    dockVelocity[i] += accel * dtSeconds;
    dockScale[i] += dockVelocity[i] * dtSeconds;
    if (Math.abs(displacement) > DOCK_SPRING_EPSILON || Math.abs(dockVelocity[i]) > DOCK_SPRING_EPSILON) settled = false;
    el.style.transform = `scale(${dockScale[i].toFixed(4)})`;
  });
  return settled;
}

function dockSpringLoop(now) {
  const dt = dockLastFrameTime ? Math.min((now - dockLastFrameTime) / 1000, 1 / 30) : 0;
  dockLastFrameTime = now;
  const settled = stepDockSpring(dt);
  if (!settled || mouseOverDock) {
    dockRaf = requestAnimationFrame(dockSpringLoop);
  } else {
    dockRaf = null;
    dockLastFrameTime = 0;
  }
}

function updateDock() {
  if (reducedMotion.matches) {
    dockItems.forEach((el, i) => {
      const target = dockTargetFor(el);
      dockScale[i] = target;
      dockVelocity[i] = 0;
      el.style.transform = target === 1 ? '' : `scale(${target.toFixed(3)})`;
    });
    return;
  }
  if (!dockRaf) {
    dockLastFrameTime = 0;
    dockRaf = requestAnimationFrame(dockSpringLoop);
  }
}

$('#dock-edge').addEventListener('mouseenter', () => setDockVisible(true));
dock.addEventListener('mouseenter', () => {
  setDockVisible(true);
  mouseOverDock = true;
  updateDock();
});
$('#dock-edge').addEventListener('mouseleave', () => setDockVisible(false));
dock.addEventListener('mouseleave', () => {
  setDockVisible(false);
  mouseOverDock = false;
  updateDock();
});

dock.addEventListener('mousemove', (e) => {
  lastMouseX = e.clientX;
  updateDock();
});

const dockTooltip = $('#dock-tooltip');

function showDockTooltip(el) {
  const box = el.getBoundingClientRect();
  dockTooltip.textContent = el.title;
  dockTooltip.style.left = `${box.left + box.width / 2}px`;
  dockTooltip.style.bottom = `${innerHeight - box.top + 12}px`;
  dockTooltip.classList.add('is-visible');
}

function hideDockTooltip() {
  dockTooltip.classList.remove('is-visible');
}

dockItems.forEach((el) => {
  el.addEventListener('mouseenter', () => showDockTooltip(el));
  el.addEventListener('mousedown', () => {
    pressedDockItem = el;
    hideDockTooltip();
    updateDock();
  });
  el.addEventListener('mouseup', () => { pressedDockItem = null; updateDock(); });
  el.addEventListener('mouseleave', () => { pressedDockItem = null; hideDockTooltip(); });
});

function showDockError(text) {
  clearTimeout(dockErrorTimer);
  dockError.textContent = text;
  dockError.hidden = false;
  requestAnimationFrame(() => dockError.classList.add('is-visible'));
  dockErrorTimer = setTimeout(() => {
    dockError.classList.remove('is-visible');
    setTimeout(() => { dockError.hidden = true; }, 180);
  }, 3200);
}

dockItems.forEach((el) => {
  el.addEventListener('click', async () => {
    const id = el.dataset.app;
    if (!window.shell) {
      showDockError('Not available in this preview');
      return;
    }
    const res = await window.shell.launchApp(id);
    if (!res.ok) showDockError(res.error);
  });
});

// ─── Clawd ──────────────────────────────────────────────────────────────────
// Patrols a lane in the corner opposite the dock; idle otherwise. Click opens
// a single-shot Q&A popover — one question, one answer, no history kept.

const clawd = $('#clawd');
const CLAWD_LANE = 130; // px it can wander left of its resting spot
let clawdX = 0;
let clawdWalkTimer = null;
let clawdWanderTimer = null;

function clawdWalkTo(x) {
  const dist = Math.abs(x - clawdX);
  const duration = Math.max(500, Math.min(2200, dist * 14));
  // No facing flip — just slide sideways and let the legs do the walking.
  clawd.style.transitionDuration = `${duration}ms`;
  clawd.style.transform = `translateX(${-x}px)`;
  clawd.classList.add('is-walking');
  clawdX = x;
  clearTimeout(clawdWalkTimer);
  clawdWalkTimer = setTimeout(() => {
    clawd.classList.remove('is-walking');
    scheduleClawdWander();
  }, duration);
}

function scheduleClawdWander() {
  clearTimeout(clawdWanderTimer);
  if (reducedMotion.matches) return; // stay put rather than teleport with no walk
  clawdWanderTimer = setTimeout(() => clawdWalkTo(Math.random() * CLAWD_LANE), 3000 + Math.random() * 6000);
}
scheduleClawdWander();

let clawdOpen = false;
function setClawdOpen(open) {
  clawdOpen = open;
  const chat = $('#clawd-chat');
  clawd.setAttribute('aria-expanded', String(open));
  if (open) {
    chat.hidden = false;
    chat.classList.remove('is-closing');
    $('#clawd-input').focus();
  } else if (!chat.hidden) {
    chat.classList.add('is-closing');
    setTimeout(() => { if (clawdOpen === false) chat.hidden = true; }, 150);
  }
}

clawd.addEventListener('click', () => setClawdOpen(!clawdOpen));
document.addEventListener('click', (e) => {
  if (clawdOpen && !e.target.closest('#clawd, #clawd-chat')) setClawdOpen(false);
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && clawdOpen) setClawdOpen(false);
});

$('#clawd-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const input = $('#clawd-input');
  const answer = $('#clawd-answer');
  const send = $('#clawd-send');
  const message = input.value.trim();
  if (!message || send.disabled) return;

  send.disabled = true;
  answer.className = 'clawd-answer is-pending';
  answer.textContent = 'Clawd is thinking…';

  if (!window.shell) {
    answer.className = 'clawd-answer is-error';
    answer.textContent = 'Not available in this preview.';
    send.disabled = false;
    return;
  }
  const res = await window.shell.askClawd(message);
  send.disabled = false;
  if (res.ok) {
    answer.className = 'clawd-answer';
    answer.textContent = res.text;
  } else {
    answer.className = 'clawd-answer is-error';
    answer.textContent = res.error;
  }
});

// ─── Boot ───────────────────────────────────────────────────────────────────

tickClock();
setInterval(tickClock, 1000);
// Placeholder: no real focus-session tracking exists yet.
$('#focused-today').textContent = '0m focused today';

if (window.shell) {
  window.shell.getState().then(render);
  window.shell.onState(render);
  loadProjects();
} else {
  render(SAMPLE);
}
