// Runs before first paint so the page never flashes the wrong theme.
(function () {
  const saved = localStorage.getItem('theme');
  const system = matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  document.documentElement.dataset.theme = saved || system;
})();
