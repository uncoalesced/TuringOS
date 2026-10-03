// Side panel open/close.

// ─── Side panel ─────────────────────────────────────────────────────────────
// Widgets (Calendar, GitHub) live here. Ctrl/⌘+J or the menu-bar clock opens
// it; it's always in the DOM, just translated off the right edge when shut —
// same reveal mechanic as the dock, not the weather card's hidden-attribute
// dance, since there's no keyframe pop here, just a slide.

let panelOpen = false;
function setPanelOpen(open) {
  panelOpen = open;
  $('#side-panel').classList.toggle('is-visible', open);
  document.documentElement.classList.toggle('panel-open', open);
  if (open) renderNotifications();
}

$('#menubar-clock').addEventListener('click', () => setPanelOpen(!panelOpen));
document.addEventListener('click', (e) => {
  if (panelOpen && !e.target.closest('#side-panel, #menubar-clock')) setPanelOpen(false);
});
document.addEventListener('keydown', (e) => {
  if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'j') {
    e.preventDefault();
    setPanelOpen(!panelOpen);
  }
  if (e.key === 'Escape' && panelOpen) setPanelOpen(false);
});
