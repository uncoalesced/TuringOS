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
  user: { name: null },
};

const SAMPLE_PROJECTS = [
  { name: 'claudeos', path: '~/code/claudeos' },
  { name: 'auth-service', path: '~/code/auth-service' },
  { name: 'dotfiles', path: '~/dotfiles' },
];

let lastSnap = null;
let userName = null;

// ─── Clock ──────────────────────────────────────────────────────────────────

function greeting(hour) {
  const part = hour < 5 ? 'Good evening' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  return userName ? `${part}, ${userName}.` : `${part}.`;
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

  const corner = $('#corner-agent');
  corner.dataset.state = s.agent.running ? 'working' : 'idle';
  corner.querySelector('.corner-label').textContent = s.agent.running ? 'Working' : 'Agent idle';
  $('#corner-task').textContent = s.agent.running && s.agent.task ? s.agent.task : '';
  $('#corner-system').textContent = [
    s.sandbox ? 'Sandbox active' : null,
    s.gameMode ? 'Game mode' : null,
    `${cpu}% CPU`,
    `${mem}% memory`,
  ].filter(Boolean).join('  ·  ');
  $('#corner-system').title = host;
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

if (window.shell) {
  window.shell.getState().then(render);
  window.shell.onState(render);
  loadProjects();
} else {
  render(SAMPLE);
}
