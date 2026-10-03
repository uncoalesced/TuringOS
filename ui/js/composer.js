// Composer: task input, @project picker, submit.

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
