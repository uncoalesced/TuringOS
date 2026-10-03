// Notification Center list in the side panel.

// ─── Notifications ──────────────────────────────────────────────────────────
// Seeded with a few demo items; real agent task completions are added on top.

const MIN = 60_000;
let notifications = [
  { app: 'claude', title: 'Completed reviewing the PR on turingos', body: '#42 ui-fixes — left 3 comments, approved with suggestions', at: Date.now() - 4 * MIN },
  { app: 'terminal', title: 'Task finished in turing-web', body: 'Tests pass · 5 files changed · ready for review', at: Date.now() - 18 * MIN },
  { app: 'github', title: 'Review requested', body: 'anthropic/turingos #51 — Debian packaging for ui/', at: Date.now() - 62 * MIN },
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
