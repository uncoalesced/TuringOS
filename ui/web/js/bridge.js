// window.shell: the page's way to the system, over turingos-bridged-ws (the
// bridge that served the page). Desktop calls and state go over /desktop to
// turingosd, the desktop service (protocol/v1/README.md); shell commands go
// over /shell to the login session's shell-helper. Opened from disk or a
// plain web server there is no window.__TURINGOS__ (see boot.js), no
// window.shell, and the page falls back to sample data.
(() => {
  if (!window.__TURINGOS__) return;

  const base = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}`;
  const listeners = { state: new Set(), voice: new Set() };
  const pending = new Map(); // id → { resolve, method }
  const waiting = []; // frames written while the socket was down
  let ws = null;
  let count = 0;
  let lastSeq = null;
  let delay = 250;

  // What a call answers when the service drops under it: the same shapes the
  // methods use for their own failures, so callers need no second error path.
  const OFFLINE = { ok: false, error: 'TuringOS is reconnecting. Try again in a moment.' };
  const offline = (method) =>
    method === 'projects_list' ? [] : method === 'open_external' ? false : OFFLINE;

  const frame = (type, data) =>
    JSON.stringify({ v: 1, type, id: `p-${++count}`, re: null, ts: Date.now(), data });

  function write(text) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(text);
    else waiting.push(text);
  }

  function call(method, params = {}) {
    return new Promise((resolve) => {
      const text = frame('rpc', { method, params });
      pending.set(`p-${count}`, { resolve, method });
      write(text);
    });
  }

  // ─── /desktop: reconnects quietly; the bridge's own overlay
  // (reconnect.js) covers the page when the bridge itself is down ──────────
  function connect() {
    ws = new WebSocket(`${base}/desktop`);
    ws.onopen = () => {
      delay = 250;
      ws.send(frame('hello', { last_seq: lastSeq }));
      waiting.splice(0).forEach((text) => ws.send(text));
    };
    ws.onmessage = (e) => {
      let msg;
      try { msg = JSON.parse(e.data); } catch { return; }
      if (typeof msg.seq === 'number') lastSeq = msg.seq;
      if (msg.type === 'rpc_result') {
        const asked = pending.get(msg.re);
        if (!asked) return;
        pending.delete(msg.re);
        if (msg.data.ok) asked.resolve(msg.data.result);
        else { console.warn(`shell.${asked.method}: ${msg.data.error}`); asked.resolve(offline(asked.method)); }
      } else if (msg.type === 'omni') {
        // Super+Space: open the command palette (its own handler is Ctrl+K)
        if (msg.data.open && !document.querySelector('.palette-scrim:not([hidden])')) {
          window.dispatchEvent(new KeyboardEvent('keydown', { key: 'k', ctrlKey: true, bubbles: true }));
        }
      } else if (listeners[msg.type]) {
        listeners[msg.type].forEach((cb) => cb(msg.data));
      }
    };
    ws.onclose = () => {
      ws = null;
      waiting.length = 0;
      pending.forEach((asked) => asked.resolve(offline(asked.method)));
      pending.clear();
      setTimeout(connect, delay);
      delay = Math.min(delay * 2, 5000);
    };
  }
  connect();
  setInterval(() => write(frame('ping', {})), 15000);

  // ─── /shell: one socket per command (shell mode is the AI-down fallback) ──
  function runShell(command) {
    return new Promise((resolve) => {
      const sock = new WebSocket(`${base}/shell`);
      let done = false;
      const finish = (res) => {
        if (done) return;
        done = true;
        resolve(res);
        try { sock.close(); } catch { /* already closed */ }
      };
      sock.onopen = () => sock.send(JSON.stringify({ command }));
      sock.onmessage = (e) => {
        let r;
        try { r = JSON.parse(e.data); } catch { return finish({ ok: false, error: 'Bad reply from the shell helper.' }); }
        if (r.status === 'ok') finish({ ok: true, output: r.output ?? '', code: r.code ?? 0 });
        else finish({ ok: false, error: (r.errors || ['The command could not run.']).join('\n') });
      };
      sock.onclose = () => finish({ ok: false, error: 'TuringOS is reconnecting. Try again in a moment.' });
    });
  }

  window.shell = {
    getState: () => call('state_get'),
    onState: (cb) => listeners.state.add(cb),
    listProjects: () => call('projects_list'),
    startAgent: (project, task, options = {}) =>
      call('agent_start', { project, task, model: options.model ?? null }),
    launchApp: (id) => call('dock_launch', { id }),
    connectGoogle: () => call('google_connect'),
    askClawd: (message) => call('clawd_ask', { message }),
    askChat: (message, model, effort) => call('chat_ask', { message, model, effort }),
    voiceStart: () => call('voice_start'),
    voiceStop: () => call('voice_stop'),
    onVoice: (cb) => listeners.voice.add(cb),
    openExternal: (url) => call('open_external', { url }),
    runShell,
    reportGfx: (report) => call('gfx_report', report),
  };

  // The shell is a browser window underneath: keep the browser's own
  // shortcuts (close, new tab, reload, zoom, history…) from reaching it.
  // Capture phase, and no stopPropagation: the page's own Ctrl+K / J / W
  // handlers still run.
  const CTRL = new Set(['w', 't', 'n', 'q', 'r', 'p', 's', 'o', 'u', 'h', 'd', 'l']);
  const CTRL_SHIFT = new Set(['n', 't', 'i', 'delete']);
  // Zoom, with or without Shift: "+" is Ctrl+Shift+= on most keyboards
  const ZOOM_KEYS = new Set(['+', '-', '=', '_', '0']);
  const ZOOM_CODES = new Set(['Equal', 'Minus', 'Digit0', 'NumpadAdd', 'NumpadSubtract', 'Numpad0']);
  window.addEventListener('keydown', (e) => {
    const key = e.key.toLowerCase();
    const mod = e.ctrlKey || e.metaKey;
    if (
      (mod && !e.shiftKey && CTRL.has(key)) ||
      (mod && e.shiftKey && CTRL_SHIFT.has(key)) ||
      (mod && (ZOOM_KEYS.has(key) || ZOOM_CODES.has(e.code))) ||
      ['f5', 'f11', 'f12'].includes(key) ||
      (e.altKey && (key === 'arrowleft' || key === 'arrowright'))
    ) e.preventDefault();
  }, true);
  // Ctrl+wheel zooms too
  window.addEventListener('wheel', (e) => {
    if (e.ctrlKey || e.metaKey) e.preventDefault();
  }, { capture: true, passive: false });

  // The shell window never navigates away: web links open in the system browser
  document.addEventListener('click', (e) => {
    const a = e.target.closest?.('a[href]');
    if (!a || !/^https?:/i.test(a.href)) return;
    e.preventDefault();
    window.shell.openExternal(a.href);
  }, true);
})();
