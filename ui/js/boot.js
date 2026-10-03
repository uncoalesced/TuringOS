// Boot: start the clock and subscribe to backend state. Loaded last.

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
