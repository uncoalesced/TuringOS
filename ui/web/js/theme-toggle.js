// Light/dark switch with the circular reveal. Initial theme: theme.js.

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
