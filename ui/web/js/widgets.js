// Side-panel widgets: GitHub PRs, Google Calendar and Wi-Fi.

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
  body.querySelector('.calendar-message')?.remove(); // one message at a time
  const p = document.createElement('p');
  p.className = 'widget-empty calendar-message';
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

// ─── Wi-Fi ──────────────────────────────────────────────────────────────────
// Scan and connect through the daemon's nmcli RPCs (bridge.wifiScan /
// wifiConnect). The list refreshes only when the panel opens or a connect
// finishes — a scan is a radio operation — while the snapshot's 10s wifi
// poll keeps just the status line honest. The password lives in wifiDraft
// across repaints and is cleared on success or cancel.

let wifiState;          // system.wifi from the snapshot: { ssid } | null; undefined until the first state
let wifiNetworks = [];
let wifiScanning = false;
let wifiConnecting = null; // ssid while a connect is in flight
let wifiFormFor = null;    // ssid whose password row is open
let wifiDraft = '';
let wifiError = '';

function wifiStatusText() {
  if (wifiScanning) return 'Scanning…';
  if (wifiConnecting) return `Connecting to ${wifiConnecting}…`;
  if (wifiState?.ssid) return `Connected to ${wifiState.ssid}`;
  if (wifiState) return 'Not connected';
  if (wifiState === null) return 'Wi-Fi is not available on this machine.';
  return 'Loading…';
}

function wifiEmpty(text) {
  return Object.assign(document.createElement('p'), { className: 'widget-empty', textContent: text });
}

function wifiRow(net) {
  const row = document.createElement(net.active ? 'div' : 'button');
  row.className = 'widget-row wifi-row';
  if (!net.active) {
    row.type = 'button';
    row.addEventListener('click', () => wifiPick(net));
  }
  const title = document.createElement('span');
  title.className = 'widget-row-title';
  title.textContent = net.ssid;
  const sub = document.createElement('span');
  sub.className = 'widget-row-sub';
  sub.textContent = [net.active ? 'Connected' : null, `${net.signal}%`, net.secure ? 'Secured' : 'Open']
    .filter(Boolean)
    .join(' · ');
  row.append(title, sub);
  if (net.active) {
    const check = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
    check.classList.add('icon');
    check.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS('http://www.w3.org/2000/svg', 'use');
    use.setAttribute('href', '#ic-check');
    check.append(use);
    row.append(check);
  }
  return row;
}

function wifiPasswordForm() {
  const form = document.createElement('form');
  form.className = 'wifi-form';
  form.autocomplete = 'off';
  const input = document.createElement('input');
  input.type = 'password';
  input.className = 'wifi-pw';
  input.id = 'wifi-password';
  input.placeholder = `Password for ${wifiFormFor}`;
  input.setAttribute('aria-label', `Password for ${wifiFormFor}`);
  input.value = wifiDraft;
  input.addEventListener('input', () => { wifiDraft = input.value; });
  const join = document.createElement('button');
  join.type = 'submit';
  join.className = 'meeting-join';
  join.textContent = wifiConnecting ? 'Connecting…' : 'Connect';
  join.disabled = !!wifiConnecting;
  const cancel = document.createElement('button');
  cancel.type = 'button';
  cancel.className = 'meeting-link';
  cancel.textContent = 'Cancel';
  cancel.addEventListener('click', () => {
    wifiFormFor = null;
    wifiDraft = '';
    wifiError = '';
    renderWifiPanel();
  });
  form.addEventListener('submit', (e) => {
    e.preventDefault();
    connectWifi(wifiFormFor, wifiDraft);
  });
  form.append(input, join, cancel);
  return form;
}

function renderWifiPanel() {
  const body = $('#wifi-body');
  if (!body) return;
  const parts = [];
  const status = document.createElement('p');
  status.className = 'wifi-status';
  status.textContent = wifiStatusText();
  parts.push(status);
  if (wifiError) {
    const err = wifiEmpty(wifiError);
    err.classList.add('wifi-error');
    parts.push(err);
  }
  if (!window.shell) {
    parts.push(wifiEmpty('Not available in this preview.'));
    body.replaceChildren(...parts);
    return;
  }
  if (wifiFormFor) parts.push(wifiPasswordForm());
  if (wifiNetworks.length) parts.push(...wifiNetworks.map(wifiRow));
  else if (wifiScanning) parts.push(wifiEmpty('Scanning…'));
  else if (!wifiError) parts.push(wifiEmpty('No networks found.'));
  body.replaceChildren(...parts);
}

function updateWifiStatus() {
  const el = $('#wifi-body .wifi-status');
  if (el) el.textContent = wifiStatusText();
}

/// From render(): the snapshot's wifi, light touch (never rebuilds — the
/// password row would lose focus)
function setWifiState(wifi) {
  wifiState = wifi;
  updateWifiStatus();
}

async function scanWifi() {
  wifiError = '';
  wifiScanning = !!window.shell;
  renderWifiPanel();
  if (!window.shell) return;
  const res = await window.shell.wifiScan();
  wifiScanning = false;
  if (res.ok) wifiNetworks = Array.isArray(res.networks) ? res.networks : [];
  else { wifiNetworks = []; wifiError = res.error || 'Could not scan for networks.'; }
  renderWifiPanel();
}

function wifiPick(net) {
  if (wifiConnecting) return;
  wifiError = '';
  if (net.secure) {
    // Empty password is fine: nmcli falls back to a profile saved earlier
    wifiFormFor = net.ssid;
    renderWifiPanel();
    $('#wifi-password')?.focus();
  } else {
    connectWifi(net.ssid, null);
  }
}

async function connectWifi(ssid, password) {
  if (wifiConnecting || !window.shell) return;
  wifiConnecting = ssid;
  wifiError = '';
  renderWifiPanel();
  const res = await window.shell.wifiConnect(ssid, password);
  wifiConnecting = null;
  if (res.ok) {
    wifiFormFor = null;
    wifiDraft = '';
    await scanWifi(); // now shows this network as the active one
  } else {
    wifiError = res.error || 'Could not connect.';
    renderWifiPanel(); // password row stays up for another try
  }
}
