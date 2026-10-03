// Dock: hidden until the cursor hits the bottom edge, magnifies on hover.

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
    // Bazaar is built into the shell, not a system app.
    if (id === 'bazaar') { window.openBazaar?.(); return; }
    if (!window.shell) {
      showDockError('Not available in this preview');
      return;
    }
    const res = await window.shell.launchApp(id);
    if (!res.ok) showDockError(res.error);
  });
});
