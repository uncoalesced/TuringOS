// Draws one state snapshot from the backend.

// ─── State ──────────────────────────────────────────────────────────────────

function render(snap) {
  // Before TuringOS is initialised, keep real system numbers but show
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
