// Clawd: pixel mascot with single-shot Q&A, opened by click or cursor shake.

// ─── Clawd ──────────────────────────────────────────────────────────────────
// Patrols its bottom-right corner, sometimes on a skateboard. Click opens a
// single-shot Q&A popover — one question, one answer, no history kept.
//
// Mood (data-mood, drawn in index.html / clawd.css):
//   idle  normal eyes, blinks       busy  holding a mug: agent or answer running
//   happy > < eyes: task done, answer in    dizzy spiral eyes: an error
//   love  heart: hovered (petted)    skate on a board while riding across
// busy is a base mood that lasts as long as the work; the others flash.

const clawd = $('#clawd');
let clawdX = 0;
let clawdWalkTimer = null;
let clawdWanderTimer = null;
let clawdBusy = { agent: false, ask: false };
let clawdFlash = null; // { mood, until }
let clawdFlashTimer = null;
let clawdSkating = false;

const CLAWD_LANE = 130; // px it wanders left of its corner, as before

function paintClawdMood() {
  const flash = clawdFlash && clawdFlash.until > Date.now() ? clawdFlash.mood : null;
  clawd.dataset.mood = flash
    || (clawdBusy.agent || clawdBusy.ask ? 'busy' : null)
    || (clawdSkating ? 'skate' : 'idle');
}

// A short-lived mood (happy, dizzy, love) that wins over busy and skating
function flashClawd(mood, ms = 2500) {
  clawdFlash = { mood, until: Date.now() + ms };
  clearTimeout(clawdFlashTimer);
  clawdFlashTimer = setTimeout(() => { clawdFlash = null; paintClawdMood(); }, ms);
  paintClawdMood();
}

function setClawdBusy(source, on) {
  clawdBusy[source] = on;
  paintClawdMood();
}

function clawdWalkTo(x, skate = false) {
  const dist = Math.abs(x - clawdX);
  const perPx = skate ? 4 : 12;
  const duration = Math.max(500, Math.min(2200, dist * perPx));
  clawd.style.transitionDuration = `${duration}ms`;
  clawd.style.transitionTimingFunction = skate ? 'cubic-bezier(.3,.1,.3,1)' : 'linear';
  clawd.style.transform = `translateX(${-x}px)`;
  clawd.classList.add('is-walking');
  clawdSkating = skate;
  paintClawdMood();
  clawdX = x;
  clearTimeout(clawdWalkTimer);
  clawdWalkTimer = setTimeout(() => {
    clawd.classList.remove('is-walking');
    clawdSkating = false;
    paintClawdMood();
    scheduleClawdWander();
  }, duration);
}

function scheduleClawdWander() {
  clearTimeout(clawdWanderTimer);
  if (reducedMotion.matches) return; // stay put rather than teleport with no walk
  clawdWanderTimer = setTimeout(() => {
    if (clawdOpen) return scheduleClawdWander(); // hold still while the chat is open
    const x = Math.random() * CLAWD_LANE;
    // Long trips are sometimes a skateboard ride, never while it's holding a mug
    const skate = Math.abs(x - clawdX) > 70 && Math.random() < 0.35 && !clawdBusy.agent && !clawdBusy.ask;
    clawdWalkTo(x, skate);
  }, 2500 + Math.random() * 6000);
}
scheduleClawdWander();

clawd.addEventListener('mouseenter', () => flashClawd('love', 1800));

// Shake the cursor anywhere — like macOS's shake-to-locate making the
// pointer huge — and Clawd's chat pops open, no click, no need to be near
// it. In kiosk mode (the real target) the window covers the whole screen,
// so this is effectively "anywhere on the OS". A "shake" is several quick
// direction reversals close together, not just fast motion in one
// direction (that's just someone moving the mouse across the screen).
// About three full back-and-forth swipes inside a second; a small wiggle
// while aiming at something shouldn't open the chat.
const CLAWD_SHAKE_WINDOW_MS = 800;
const CLAWD_SHAKE_MIN_DIST = 600; // px of total horizontal travel inside the window
const CLAWD_SHAKE_MIN_REVERSALS = 6;

let clawdShakeSamples = []; // { x, t }

document.addEventListener('mousemove', (e) => {
  if (clawdOpen) { clawdShakeSamples = []; return; }
  // Sweeping back and forth across the dock (or the bottom strip that
  // reveals it) is browsing apps, not a shake. Same for scrubbing through the
  // notification panel or the Cmd+K palette.
  if (panelOpen || document.querySelector('.palette')?.checkVisibility()
    || e.target.closest?.('#dock, .dock-edge, #side-panel, .palette, .app-window')
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
  setClawdBusy('ask', true);
  answer.className = 'clawd-answer is-pending';
  answer.textContent = 'Clawd is thinking…';

  if (!window.shell) {
    answer.className = 'clawd-answer is-error';
    answer.textContent = 'Not available in this preview.';
    send.disabled = false;
    setClawdBusy('ask', false);
    flashClawd('dizzy');
    return;
  }
  const res = await window.shell.askClawd(message);
  send.disabled = false;
  setClawdBusy('ask', false);
  if (res.ok) {
    answer.className = 'clawd-answer';
    answer.textContent = res.text;
    flashClawd('happy');
  } else {
    answer.className = 'clawd-answer is-error';
    answer.textContent = res.error;
    flashClawd('dizzy', 4000);
  }
});
