// Side-panel widgets: GitHub PRs and Google Calendar.

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
