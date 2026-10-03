// Menu-bar clock and hero greeting.

// ─── Clock ──────────────────────────────────────────────────────────────────

function greeting(hour) {
  const part = hour < 5 ? 'Good evening' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  return userName ? `${part}, ${userName}.` : `${part}.`;
}

function tickClock() {
  const now = new Date();
  const time = now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
  const shortDate = now.toLocaleDateString([], { weekday: 'short', day: 'numeric', month: 'short' });

  $('#menubar-clock').textContent = `${shortDate}  ${time}`;
  $('#hero-time').textContent = time;
  $('#hero-greeting').textContent = greeting(now.getHours());
}
