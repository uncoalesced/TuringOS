// "Reconnecting…" overlay (Phase 3 fallback). Served by turingos-bridged-ws
// (the trust-model stack, Brave kiosk), the page loses its backend when the
// bridge dies; systemd restarts it. Until /health answers again, cover the
// page and point at Super+Esc. Under Tauri the backend is in-process, and a
// page that never reached /health (a plain static server) isn't on a bridge:
// nothing to do in either case.
//
// window.turingosSocket(path, onMessage) → { send, close }: a WebSocket to
// the bridge that reconnects with backoff, for the Phase 1 UI to build on.
(() => {
  if (window.__TAURI__ || !/^https?:$/.test(location.protocol)) return;

  const overlay = document.getElementById('reconnect');
  let onBridge = false;
  let delay = 2000;

  async function check() {
    let up = false;
    try {
      up = (await fetch('/health', { cache: 'no-store' })).ok;
    } catch {
      up = false;
    }
    if (up) onBridge = true;
    if (!onBridge) return; // not served by the bridge: stop polling
    overlay.hidden = up;
    delay = up ? 2000 : Math.min(delay * 1.5, 10000);
    setTimeout(check, delay);
  }
  check();

  window.turingosSocket = (path, onMessage) => {
    const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}${path}`;
    let ws;
    let wait = 500;
    let closed = false;
    const open = () => {
      ws = new WebSocket(url);
      ws.onopen = () => { wait = 500; };
      ws.onmessage = (e) => onMessage(JSON.parse(e.data));
      ws.onclose = () => {
        if (closed) return;
        setTimeout(open, wait);
        wait = Math.min(wait * 2, 10000);
      };
    };
    open();
    return {
      send(msg) {
        if (ws.readyState !== WebSocket.OPEN) return false;
        ws.send(JSON.stringify(msg));
        return true;
      },
      close() {
        closed = true;
        ws.close();
      },
    };
  };
})();
