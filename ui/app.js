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
let lastAgentRunning = false;
let lastAgentTask = '';

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

// Shown until a real calendar is connected (and when it has nothing coming
// up), so the demo always has a meeting to look at.
const DEMO_MEETING = {
  title: 'Design sync — TuringOS demo',
  start: (() => { const d = new Date(); d.setHours(16, 30, 0, 0); return d.toISOString(); })(),
  meta: '30 min · Google Meet',
};

function meetingCard(ev, { demo }) {
  const wrap = document.createElement('div');
  wrap.className = 'meeting';
  const when = document.createElement('p');
  when.className = 'meeting-when';
  when.textContent = formatEventTime(ev.start) || 'Upcoming';
  const title = document.createElement('p');
  title.className = 'meeting-title';
  title.textContent = ev.title;
  const meta = document.createElement('p');
  meta.className = 'meeting-meta';
  meta.textContent = ev.meta || 'Next on your calendar';
  const foot = document.createElement('div');
  foot.className = 'meeting-foot';
  const join = document.createElement('button');
  join.type = 'button';
  join.className = 'meeting-join';
  join.textContent = 'Join';
  foot.append(join);
  if (demo) {
    const link = document.createElement('button');
    link.type = 'button';
    link.id = 'calendar-connect';
    link.className = 'meeting-link';
    link.textContent = 'Connect Google Calendar';
    link.addEventListener('click', connectGoogle);
    foot.append(link);
  }
  wrap.append(when, title, meta, foot);
  return wrap;
}

let calendarKey = '';
function renderCalendar(cal) {
  const ev = cal.connected && cal.nextEvent;
  const key = ev ? `${ev.title}|${ev.start}` : 'demo';
  if (key === calendarKey) return; // state pushes every few seconds; don't rebuild
  calendarKey = key;
  $('#calendar-body').replaceChildren(ev ? meetingCard(ev, { demo: false }) : meetingCard(DEMO_MEETING, { demo: !cal.connected }));
}

// ─── Notifications ──────────────────────────────────────────────────────────
// Seeded with a few demo items; real agent task completions are added on top.

const MIN = 60_000;
let notifications = [
  { app: 'claude', title: 'Completed reviewing the PR on claudeos', body: '#42 ui-fixes — left 3 comments, approved with suggestions', at: Date.now() - 4 * MIN },
  { app: 'terminal', title: 'Task finished in turing-web', body: 'Tests pass · 5 files changed · ready for review', at: Date.now() - 18 * MIN },
  { app: 'github', title: 'Review requested', body: 'anthropic/claudeos #51 — Debian packaging for ui/', at: Date.now() - 62 * MIN },
];

const NOTIF_ICON = { claude: 'claude-spark', terminal: 'ic-terminal', github: 'ic-github' };

function timeAgo(t) {
  const m = Math.round((Date.now() - t) / MIN);
  if (m < 1) return 'now';
  if (m < 60) return `${m}m ago`;
  return `${Math.round(m / 60)}h ago`;
}

function renderNotifications() {
  const list = $('#notif-list');
  $('#notif-clear').hidden = notifications.length === 0;
  if (!notifications.length) {
    list.replaceChildren(Object.assign(document.createElement('p'), { className: 'notif-empty', textContent: 'No new notifications' }));
    return;
  }
  list.replaceChildren(...notifications.map((n, i) => {
    const card = document.createElement('article');
    card.className = 'notif';
    card.style.setProperty('--i', i);
    const app = document.createElement('span');
    app.className = 'notif-app';
    app.dataset.app = n.app;
    const svgNS = 'http://www.w3.org/2000/svg';
    const svg = document.createElementNS(svgNS, 'svg');
    svg.setAttribute('class', n.app === 'claude' ? 'spark' : 'icon');
    svg.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS(svgNS, 'use');
    use.setAttribute('href', `#${NOTIF_ICON[n.app] || 'ic-check'}`);
    svg.append(use);
    app.append(svg);
    const text = document.createElement('div');
    const top = document.createElement('div');
    top.className = 'notif-top';
    top.append(
      Object.assign(document.createElement('p'), { className: 'notif-title', textContent: n.title }),
      Object.assign(document.createElement('time'), { className: 'notif-time', textContent: timeAgo(n.at) }),
    );
    text.append(top, Object.assign(document.createElement('p'), { className: 'notif-body', textContent: n.body }));
    card.append(app, text);
    return card;
  }));
  // Widgets follow the notifications in the stagger.
  document.querySelectorAll('.side-panel .panel-card').forEach((el, j) => el.style.setProperty('--i', notifications.length + j));
}

function notify(n) {
  notifications.unshift({ at: Date.now(), ...n });
  renderNotifications();
}

$('#notif-clear').addEventListener('click', () => {
  notifications = [];
  renderNotifications();
});

renderNotifications();

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
  document.documentElement.classList.toggle('panel-open', open);
  if (open) renderNotifications();
}

$('#menubar-clock').addEventListener('click', () => setPanelOpen(!panelOpen));
document.addEventListener('click', (e) => {
  if (panelOpen && !e.target.closest('#side-panel, #menubar-clock')) setPanelOpen(false);
});
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
  if (lastAgentRunning && !s.agent.running) {
    notify({ app: 'terminal', title: 'Agent task finished', body: lastAgentTask || 'The sandboxed agent is done.' });
  }
  lastAgentRunning = s.agent.running;
  if (s.agent.task) lastAgentTask = s.agent.task;
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

// ─── Model picker ───────────────────────────────────────────────────────────
// Which model/effort the next agent run uses. Persisted locally; passed
// through to the backend as env vars on start (CLAUDEOS_AGENT_MODEL/EFFORT) —
// additive only, agent/claude.sh doesn't read them yet, so this is inert
// until that's wired up, not a silent no-op pretending to work today.

const MODELS = [
  { id: 'claude-fable-5-1', label: 'Fable 5.1', desc: 'For your toughest challenges' },
  { id: 'claude-opus-5-5', label: 'Opus 5.5', desc: 'Most capable for ambitious work' },
  { id: 'claude-sonnet-5', label: 'Sonnet 5', desc: 'Most efficient for everyday tasks' },
  { id: 'claude-haiku-4-5', label: 'Haiku 4.5', desc: 'Fastest for quick answers' },
];
const EFFORTS = [
  { id: 'low', label: 'Low' },
  { id: 'medium', label: 'Medium', isDefault: true },
  { id: 'high', label: 'High' },
  { id: 'xhigh', label: 'Extra' },
  { id: 'max', label: 'Max' },
];

let modelChoice = localStorage.getItem('model') || 'claude-sonnet-5';
let effortChoice = localStorage.getItem('effort') || 'medium';
if (!MODELS.some((m) => m.id === modelChoice)) modelChoice = 'claude-sonnet-5';
if (!EFFORTS.some((e) => e.id === effortChoice)) effortChoice = 'medium';

const modelMenu = $('#model-menu');
const modelPickerButton = $('#model-picker-button');
let modelMenuOpen = false;

function renderModelPickerButton() {
  $('#model-picker-label').textContent = MODELS.find((m) => m.id === modelChoice)?.label || modelChoice;
  $('#model-picker-effort-label').textContent = EFFORTS.find((e) => e.id === effortChoice)?.label || effortChoice;
}

function renderModelMenu() {
  const modelsPage = $('#model-menu-page-models');
  modelsPage.replaceChildren(...MODELS.map((m) => {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'model-option';
    el.setAttribute('role', 'menuitemradio');
    el.setAttribute('aria-checked', String(m.id === modelChoice));
    el.innerHTML = `
      <span class="model-option-text">
        <span class="model-option-name">${m.label}</span>
        <span class="model-option-desc">${m.desc}</span>
      </span>
      ${m.id === modelChoice ? '<svg class="icon" aria-hidden="true"><use href="#ic-check" /></svg>' : ''}
    `;
    el.addEventListener('click', () => {
      modelChoice = m.id;
      localStorage.setItem('model', modelChoice);
      renderModelPickerButton();
      renderModelMenu();
      closeModelMenu();
    });
    return el;
  }));

  const divider = document.createElement('hr');
  divider.className = 'model-menu-divider';
  const effortRow = document.createElement('button');
  effortRow.type = 'button';
  effortRow.className = 'model-menu-more';
  effortRow.innerHTML = `<span>Effort</span><span class="model-menu-more-value">${EFFORTS.find((e) => e.id === effortChoice)?.label}<svg class="icon" aria-hidden="true"><use href="#ic-chevron-right" /></svg></span>`;
  effortRow.addEventListener('click', () => showModelMenuPage('effort'));

  const moreDivider = document.createElement('hr');
  moreDivider.className = 'model-menu-divider';
  const moreRow = document.createElement('button');
  moreRow.type = 'button';
  moreRow.className = 'model-menu-more';
  moreRow.innerHTML = '<span>More models</span><svg class="icon" aria-hidden="true"><use href="#ic-chevron-right" /></svg>';
  moreRow.addEventListener('click', () => setHint('More models coming soon'));

  modelsPage.append(divider, effortRow, moreDivider, moreRow);

  const effortPage = $('#model-menu-page-effort');
  const existingOptions = effortPage.querySelectorAll('.effort-option');
  existingOptions.forEach((el) => el.remove());
  effortPage.append(...EFFORTS.map((eff) => {
    const el = document.createElement('button');
    el.type = 'button';
    el.className = 'effort-option';
    el.setAttribute('role', 'menuitemradio');
    el.setAttribute('aria-checked', String(eff.id === effortChoice));
    el.innerHTML = `
      <span class="model-option-text">${eff.label}</span>
      ${eff.isDefault ? '<span class="effort-default-tag">Default</span>' : ''}
      ${eff.id === effortChoice ? '<svg class="icon" aria-hidden="true"><use href="#ic-check" /></svg>' : ''}
    `;
    el.addEventListener('click', () => {
      effortChoice = eff.id;
      localStorage.setItem('effort', effortChoice);
      renderModelPickerButton();
      renderModelMenu();
      showModelMenuPage('models');
      closeModelMenu();
    });
    return el;
  }));
}

function showModelMenuPage(page) {
  $('#model-menu-page-models').hidden = page !== 'models';
  $('#model-menu-page-effort').hidden = page !== 'effort';
}

function openModelMenu() {
  renderModelMenu();
  showModelMenuPage('models');
  modelMenu.hidden = false;
  modelMenuOpen = true;
  modelPickerButton.setAttribute('aria-expanded', 'true');
}

function closeModelMenu() {
  modelMenu.hidden = true;
  modelMenuOpen = false;
  modelPickerButton.setAttribute('aria-expanded', 'false');
}

modelPickerButton.addEventListener('click', () => (modelMenuOpen ? closeModelMenu() : openModelMenu()));
$('#model-menu-back').addEventListener('click', () => showModelMenuPage('models'));
document.addEventListener('click', (e) => {
  if (modelMenuOpen && !e.target.closest('.model-picker')) closeModelMenu();
});
document.addEventListener('keydown', (e) => {
  if (e.key === 'Escape' && modelMenuOpen) closeModelMenu();
});

renderModelPickerButton();

// ─── Voice input (mic button) ───────────────────────────────────────────────
// Chromium's built-in Web Speech API — no new dependency, no new
// credentials. Depends on Chromium's own speech backend being reachable;
// unverified on the offline/VM target, so it fails soft with a clear
// message rather than pretending to work.

const micButton = $('#composer-mic');
const SpeechRecognitionCtor = window.SpeechRecognition || window.webkitSpeechRecognition;
let recognizer = null;
let micListening = false;

function setMicListening(on) {
  micListening = on;
  micButton.setAttribute('aria-pressed', String(on));
  micButton.querySelector('use').setAttribute('href', on ? '#ic-mic-off' : '#ic-mic');
  micButton.setAttribute('aria-label', on ? 'Stop dictation' : 'Dictate');
}

if (!SpeechRecognitionCtor) {
  micButton.disabled = true;
  micButton.title = 'Voice input is not available in this build';
} else {
  micButton.addEventListener('click', () => {
    if (micListening) {
      recognizer?.stop();
      return;
    }
    recognizer = new SpeechRecognitionCtor();
    recognizer.continuous = true;
    recognizer.interimResults = false;
    recognizer.lang = navigator.language || 'en-US';
    const baseText = input.value ? `${input.value.trim()} ` : '';
    recognizer.onstart = () => setMicListening(true);
    recognizer.onresult = (e) => {
      let transcript = '';
      for (let i = e.resultIndex; i < e.results.length; i++) transcript += e.results[i][0].transcript;
      input.value = baseText + transcript;
      sync();
    };
    recognizer.onerror = (e) => {
      setHint(e.error === 'not-allowed' ? 'Microphone access was denied' : 'Voice input isn’t working right now', 'error');
    };
    recognizer.onend = () => setMicListening(false);
    recognizer.start();
  });
}

async function submitTask(task) {
  const res = await window.shell.startAgent(project.path, task, { model: modelChoice, effort: effortChoice });
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

// No @project attached: this is a question, not a coding task — answer it
// directly instead of starting a sandboxed Claude Code agent. That's the
// actual difference between "chat with Claude" and "have Claude Code work
// on my repo": whether a project is attached, not a separate mode to pick.
async function submitChat(question) {
  const answer = $('#composer-answer');
  send.disabled = true;
  answer.className = 'composer-answer is-pending';
  answer.textContent = 'Thinking…';
  const res = await window.shell.askChat(question, modelChoice, effortChoice);
  send.disabled = !input.value.trim();
  if (!res.ok) {
    answer.className = 'composer-answer is-error';
    answer.textContent = res.error;
    return;
  }
  answer.className = 'composer-answer';
  answer.textContent = res.text;
  input.value = '';
  sync();
}

async function submit() {
  const task = input.value.trim();
  if (!task) return;
  if (!window.shell || !lastSnap?.live) {
    setHint('Sample mode: nothing was started', 'error');
    return;
  }
  if (project) {
    await submitTask(task);
  } else {
    await submitChat(task);
  }
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
// Magnification follows buildui.com's "Magnified Dock" recipe: each icon's
// distance from the cursor maps linearly to a target *size* (not a scale),
// and a spring drives the real width/height toward it. Because the size is
// real layout, a growing icon pushes its neighbours apart and widens the
// tray instead of overlapping them.

const dock = $('#dock');
const dockItems = [...document.querySelectorAll('.dock-item')];
const dockError = $('#dock-error');
const dockTooltip = $('#dock-tooltip');

const DOCK_BASE = 48; // px, resting tile size
const DOCK_MAX = 84; // px, tile size directly under the cursor
const DOCK_RANGE = 150; // px, distance at which a tile is back to resting size
const DOCK_HIDE_DELAY = 250; // ms grace period before hiding, so crossing the gap between edge and dock doesn't flicker it shut

// The recipe's own spring (Framer Motion: mass 0.1, stiffness 150,
// damping 12), integrated here in plain JS since there's no Framer Motion.
const DOCK_SPRING = { mass: 0.1, stiffness: 150, damping: 12 };
const DOCK_SPRING_STEP = 1 / 240; // s — substep so a slow frame doesn't destabilise the spring
const DOCK_SETTLE = 0.05; // px and px/s under which a tile counts as settled

let dockHideTimer = null;
let dockRaf = null;
let dockLastFrameTime = 0;
let dockErrorTimer = null;
let dockMouseX = null; // null = cursor not over the dock
let dockHovered = null; // tile the tooltip is pointing at
const dockSize = dockItems.map(() => DOCK_BASE);
const dockVelocity = dockItems.map(() => 0);

function setDockVisible(visible) {
  clearTimeout(dockHideTimer);
  if (visible) {
    dock.classList.add('is-visible');
    $('#sample-badge').classList.add('is-hidden');
  } else {
    dockHideTimer = setTimeout(() => {
      dock.classList.remove('is-visible');
      resetDock();
      $('#sample-badge').classList.remove('is-hidden');
    }, DOCK_HIDE_DELAY);
  }
}

function applyDockSize(el, size) {
  el.style.width = `${size.toFixed(2)}px`;
  el.style.height = `${size.toFixed(2)}px`;
}

function resetDock() {
  if (dockRaf) cancelAnimationFrame(dockRaf);
  dockRaf = null;
  dockLastFrameTime = 0;
  dockMouseX = null;
  dockItems.forEach((el, i) => {
    dockSize[i] = DOCK_BASE;
    dockVelocity[i] = 0;
    el.style.width = '';
    el.style.height = '';
  });
  hideDockTooltip();
}

// Target size for one tile: linear falloff from DOCK_MAX at the cursor to
// DOCK_BASE at DOCK_RANGE away — the recipe's useTransform([-150, 0, 150]).
function dockTargetFor(el) {
  if (dockMouseX === null) return DOCK_BASE;
  const box = el.getBoundingClientRect();
  const dist = Math.abs(dockMouseX - (box.left + box.width / 2));
  const t = Math.max(0, 1 - dist / DOCK_RANGE);
  return DOCK_BASE + (DOCK_MAX - DOCK_BASE) * t;
}

function stepDock(dt) {
  // Read every target first, then write — reading layout between writes
  // would make each tile see its neighbours half-updated.
  const targets = dockItems.map(dockTargetFor);
  let settled = true;
  const { mass, stiffness, damping } = DOCK_SPRING;
  dockItems.forEach((el, i) => {
    for (let t = 0; t < dt; t += DOCK_SPRING_STEP) {
      const h = Math.min(DOCK_SPRING_STEP, dt - t);
      const accel = (-stiffness * (dockSize[i] - targets[i]) - damping * dockVelocity[i]) / mass;
      dockVelocity[i] += accel * h; // semi-implicit Euler: velocity first, then position
      dockSize[i] += dockVelocity[i] * h;
    }
    if (Math.abs(dockSize[i] - targets[i]) > DOCK_SETTLE || Math.abs(dockVelocity[i]) > DOCK_SETTLE) settled = false;
    applyDockSize(el, dockSize[i]);
  });
  if (dockHovered) positionDockTooltip(dockHovered);
  return settled;
}

function dockLoop(now) {
  const dt = dockLastFrameTime ? Math.min((now - dockLastFrameTime) / 1000, 1 / 30) : 1 / 60;
  dockLastFrameTime = now;
  const settled = stepDock(dt);
  if (!settled || dockMouseX !== null) {
    dockRaf = requestAnimationFrame(dockLoop);
  } else {
    dockRaf = null;
    dockLastFrameTime = 0;
  }
}

function updateDock() {
  if (reducedMotion.matches) {
    const targets = dockItems.map(dockTargetFor);
    dockItems.forEach((el, i) => {
      dockSize[i] = targets[i];
      dockVelocity[i] = 0;
      applyDockSize(el, targets[i]);
    });
    if (dockHovered) positionDockTooltip(dockHovered);
    return;
  }
  if (!dockRaf) {
    dockLastFrameTime = 0;
    dockRaf = requestAnimationFrame(dockLoop);
  }
}

$('#dock-edge').addEventListener('mouseenter', () => setDockVisible(true));
$('#dock-edge').addEventListener('mouseleave', () => setDockVisible(false));
dock.addEventListener('mouseenter', () => setDockVisible(true));
dock.addEventListener('mousemove', (e) => {
  dockMouseX = e.clientX;
  updateDock();
});
dock.addEventListener('mouseleave', () => {
  setDockVisible(false);
  dockMouseX = null;
  updateDock();
});

// Tooltip follows its tile every frame, since the tile keeps growing
// after the cursor lands on it.
function positionDockTooltip(el) {
  const box = el.getBoundingClientRect();
  dockTooltip.style.left = `${box.left + box.width / 2}px`;
  dockTooltip.style.bottom = `${innerHeight - box.top + 10}px`;
}

function showDockTooltip(el) {
  dockHovered = el;
  dockTooltip.textContent = el.dataset.label;
  positionDockTooltip(el);
  dockTooltip.classList.add('is-visible');
}

function hideDockTooltip() {
  dockHovered = null;
  dockTooltip.classList.remove('is-visible');
}

dockItems.forEach((el) => {
  el.addEventListener('mouseenter', () => showDockTooltip(el));
  el.addEventListener('mouseleave', hideDockTooltip);
  el.addEventListener('mousedown', hideDockTooltip);
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

// Shake the cursor anywhere — like macOS's shake-to-locate making the
// pointer huge — and Clawd's chat pops open, no click, no need to be near
// it. In kiosk mode (the real target) the window covers the whole screen,
// so this is effectively "anywhere on the OS". A "shake" is several quick
// direction reversals close together, not just fast motion in one
// direction (that's just someone moving the mouse across the screen).
const CLAWD_SHAKE_WINDOW_MS = 450;
const CLAWD_SHAKE_MIN_DIST = 220; // px of total horizontal travel inside the window
const CLAWD_SHAKE_MIN_REVERSALS = 3;

let clawdShakeSamples = []; // { x, t }

document.addEventListener('mousemove', (e) => {
  if (clawdOpen) { clawdShakeSamples = []; return; }
  // Sweeping back and forth across the dock (or the bottom strip that
  // reveals it) is browsing apps, not a shake. Same for scrubbing through the
  // notification panel or the Cmd+K palette.
  if (panelOpen || document.querySelector('.palette')?.checkVisibility()
    || e.target.closest?.('#dock, .dock-edge, #side-panel, .palette')
    || e.clientY > innerHeight - 120) {
    clawdShakeSamples = [];
    return;
  }
  const now = performance.now();
  clawdShakeSamples.push({ x: e.clientX, t: now });
  clawdShakeSamples = clawdShakeSamples.filter((s) => now - s.t <= CLAWD_SHAKE_WINDOW_MS);
  if (clawdShakeSamples.length < 5) return;

  let dist = 0;
  let reversals = 0;
  let lastDx = 0;
  for (let i = 1; i < clawdShakeSamples.length; i++) {
    const dx = clawdShakeSamples[i].x - clawdShakeSamples[i - 1].x;
    dist += Math.abs(dx);
    if (lastDx !== 0 && dx !== 0 && Math.sign(dx) !== Math.sign(lastDx)) reversals++;
    if (dx !== 0) lastDx = dx;
  }
  if (dist >= CLAWD_SHAKE_MIN_DIST && reversals >= CLAWD_SHAKE_MIN_REVERSALS) {
    clawdShakeSamples = [];
    setClawdOpen(true);
  }
});

let clawdOpen = false;
function setClawdOpen(open) {
  clawdOpen = open;
  const chat = $('#clawd-chat');
  clawd.setAttribute('aria-expanded', String(open));
  if (open) {
    chat.hidden = false;
    chat.classList.remove('is-closing');
    // A shake doesn't click into the window, so it may not have real OS
    // keyboard focus yet — window.focus() brings the app forward first,
    // otherwise the input looks focused but keystrokes go elsewhere.
    window.focus();
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

$('#clawd-input').addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
    e.preventDefault();
    $('#clawd-form').requestSubmit();
  }
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
