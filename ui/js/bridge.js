// window.shell: the only bridge between the page and the system, backed by
// the Tauri app (ui/src-tauri). In a plain browser there is no window.shell,
// and the page falls back to sample data.
(() => {
  const tauri = window.__TAURI__;
  if (!tauri) return;
  const { invoke } = tauri.core;

  window.shell = {
    getState: () => invoke('state_get'),
    onState: (cb) => tauri.event.listen('state', (e) => cb(e.payload)),
    listProjects: () => invoke('projects_list'),
    startAgent: (project, task, options = {}) =>
      invoke('agent_start', { project, task, model: options.model ?? null }),
    launchApp: (id) => invoke('dock_launch', { id }),
    connectGoogle: () => invoke('google_connect'),
    askClawd: (message) => invoke('clawd_ask', { message }),
    askChat: (message, model, effort) => invoke('chat_ask', { message, model, effort }),
    voiceStart: () => invoke('voice_start'),
    voiceStop: () => invoke('voice_stop'),
    onVoice: (cb) => tauri.event.listen('voice', (e) => cb(e.payload)),
    openExternal: (url) => invoke('open_external', { url }),
  };

  // The window is frameless (fullscreen in kiosk mode): Ctrl/⌘+Q quits
  document.addEventListener('keydown', (e) => {
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'q') {
      e.preventDefault();
      invoke('app_quit');
    }
  });

  // The shell window never navigates away: web links open in the system browser
  document.addEventListener('click', (e) => {
    const a = e.target.closest?.('a[href]');
    if (!a || !/^https?:/i.test(a.href)) return;
    e.preventDefault();
    window.shell.openExternal(a.href);
  }, true);
})();
