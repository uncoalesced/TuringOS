// Command palette (Cmd/Ctrl+K) — prototype over the shared mock catalogue.
// Takes Cmd/Ctrl+K in the capture phase, before any document-level handler.
(() => {
  const { PLUGINS, installed, el } = window.TuringCatalog;
  const icon = (id) => window.TuringCatalog.icon(id, null);

  const click = (sel) => () => document.querySelector(sel)?.click();
  const COMMANDS = [
    { id: 'plugins', name: 'Plugins', desc: 'Browse new plugins available', icon: 'ic-plus', hint: 'Browse', run: () => openPlugins() },
    { id: 'bazaar', name: 'Open Bazaar', desc: 'Skills and plugins store', icon: 'ic-bag', run: () => window.openBazaar?.() },
    { id: 'terminal', name: 'Open Terminal', desc: 'Launch a terminal window', icon: 'ic-terminal', run: click('.dock-item[data-app="terminal"]') },
    { id: 'browser', name: 'Open Browser', desc: 'Launch the web browser', icon: 'ic-globe', run: click('.dock-item[data-app="browser"]') },
    { id: 'files', name: 'Open Files', desc: 'Browse your home folder', icon: 'ic-folder', run: click('.dock-item[data-app="files"]') },
    { id: 'theme', name: 'Toggle theme', desc: 'Switch light and dark', icon: 'ic-settings', run: click('#theme-toggle') },
    { id: 'settings', name: 'Settings', desc: 'System preferences', icon: 'ic-settings', run: click('.dock-item[data-app="settings"]') },
  ];

  // ─── DOM ──────────────────────────────────────────────────────────────────
  const scrim = el('div', 'palette-scrim');
  scrim.hidden = true;
  const box = el('div', 'palette');
  box.setAttribute('role', 'dialog');
  box.setAttribute('aria-label', 'Command palette');
  const head = el('div', 'palette-head');
  const spark = icon('claude-spark');
  spark.classList.add('palette-spark');
  const crumb = el('span', 'palette-crumb', 'Plugins');
  crumb.hidden = true;
  const input = el('input', 'palette-input');
  input.type = 'text';
  input.spellcheck = false;
  input.placeholder = 'Search commands and plugins…';
  input.setAttribute('aria-controls', 'palette-list');
  head.append(spark, crumb, input);
  const list = el('ul', 'palette-list');
  list.id = 'palette-list';
  list.setAttribute('role', 'listbox');
  const foot = el('div', 'palette-foot');
  for (const [k, t] of [['↑↓', 'move'], ['↵', 'select'], ['esc', 'close']]) {
    const s = el('span');
    s.append(el('kbd', null, k), ` ${t}`);
    foot.append(s);
  }
  box.append(head, list, foot);
  scrim.append(box);
  document.body.append(scrim);

  // ─── State ────────────────────────────────────────────────────────────────
  let open = false;
  let mode = 'root'; // 'root' | 'plugins'
  let rows = []; // [{ kind, data, node }]
  let active = 0;

  // Subsequence fuzzy match; prefix/word-start matches score higher.
  function score(q, text) {
    if (!q) return 1;
    const t = text.toLowerCase();
    if (t.startsWith(q)) return 100;
    if (t.includes(` ${q}`)) return 80;
    if (t.includes(q)) return 60;
    let i = 0;
    for (const c of t) if (c === q[i]) i++;
    return i === q.length ? 20 : 0;
  }
  const rank = (items, q, key) =>
    items.map((it) => ({ it, s: score(q, key(it)) })).filter((x) => x.s > 0).sort((a, b) => b.s - a.s).map((x) => x.it);

  function commandRow(cmd) {
    const li = el('li', 'palette-item');
    const ic = el('span', 'palette-icon');
    ic.append(icon(cmd.icon));
    const body = el('div', 'palette-body');
    body.append(el('div', 'palette-title', cmd.name), el('div', 'palette-desc', cmd.desc));
    li.append(ic, body);
    if (cmd.hint) li.append(el('span', 'palette-hint', cmd.hint));
    return li;
  }

  function pluginRow(p) {
    const li = el('li', 'palette-item');
    li.dataset.plugin = p.id;
    const ic = el('span', 'palette-icon', p.name[0]);
    const body = el('div', 'palette-body');
    const title = el('div', 'palette-title', p.name);
    if (p.isNew && !installed.has(p.id)) title.append(el('span', 'palette-badge', 'New'));
    body.append(title, el('div', 'palette-desc', p.desc));
    const btn = el('button', 'palette-install');
    btn.type = 'button';
    btn.tabIndex = -1;
    paintInstall(btn, installed.has(p.id));
    btn.addEventListener('click', (e) => {
      e.stopPropagation();
      toggleInstall(p);
    });
    li.append(ic, body, btn);
    return li;
  }

  function paintInstall(btn, on) {
    btn.replaceChildren();
    btn.classList.toggle('is-installed', on);
    if (on) btn.append(icon('ic-check'), 'Installed');
    else btn.append('Install');
  }

  function toggleInstall(p) {
    if (installed.has(p.id)) installed.delete(p.id);
    else installed.add(p.id);
    render();
  }

  function render() {
    const q = input.value.trim().toLowerCase();
    list.replaceChildren();
    rows = [];
    crumb.hidden = mode !== 'plugins';
    input.placeholder = mode === 'plugins' ? 'Search plugins…' : 'Search commands and plugins…';

    const addSection = (label) => list.append(el('li', 'palette-section', label));
    const add = (kind, data) => {
      const node = kind === 'plugin' ? pluginRow(data) : commandRow(data);
      node.setAttribute('role', 'option');
      const idx = rows.length;
      node.addEventListener('mousemove', () => idx !== active && setActive(idx));
      node.addEventListener('click', () => activate(idx));
      rows.push({ kind, data, node });
      list.append(node);
    };

    if (mode === 'plugins') {
      const ps = rank(PLUGINS, q, (p) => `${p.name} ${p.desc}`);
      if (ps.length) addSection(`${PLUGINS.length} new plugins available`);
      ps.forEach((p) => add('plugin', p));
    } else {
      const cmds = rank(COMMANDS, q, (c) => c.name);
      // Typing "plug…" surfaces the plugin list inline.
      const showPlugins = q && score(q, 'plugins') >= 60;
      const ps = q ? rank(PLUGINS, q, (p) => p.name) : [];
      if (showPlugins) {
        addSection(`${PLUGINS.length} new plugins available`);
        PLUGINS.forEach((p) => add('plugin', p));
      }
      const rest = cmds.filter((c) => !(showPlugins && c.id === 'plugins'));
      if (rest.length) {
        addSection('Commands');
        rest.forEach((c) => add('command', c));
      }
      if (!showPlugins && ps.length) {
        addSection('Plugins');
        ps.forEach((p) => add('plugin', p));
      }
    }
    if (!rows.length) list.append(el('li', 'palette-empty', 'No results'));
    setActive(Math.min(active, Math.max(rows.length - 1, 0)));
  }

  function setActive(i) {
    if (!rows.length) return;
    active = (i + rows.length) % rows.length;
    rows.forEach((r, j) => {
      r.node.classList.toggle('is-active', j === active);
      r.node.setAttribute('aria-selected', String(j === active));
    });
    rows[active].node.scrollIntoView({ block: 'nearest' });
  }

  function activate(i) {
    const r = rows[i];
    if (!r) return;
    if (r.kind === 'plugin') return toggleInstall(r.data);
    if (r.data.id === 'plugins') return r.data.run();
    setOpen(false);
    r.data.run();
  }

  function openPlugins() {
    mode = 'plugins';
    input.value = '';
    active = 0;
    render();
    input.focus();
  }

  function setOpen(next) {
    if (next === open) return;
    open = next;
    if (open) {
      mode = 'root';
      input.value = '';
      active = 0;
      render();
      scrim.hidden = false;
      // Entrance only; closing is instant so a rapid Cmd+K toggle never lags.
      scrim.classList.remove('is-entering');
      void scrim.offsetWidth;
      scrim.classList.add('is-entering');
      input.focus();
    } else {
      scrim.hidden = true;
      scrim.classList.remove('is-entering');
    }
  }

  // ─── Input ────────────────────────────────────────────────────────────────
  input.addEventListener('input', () => {
    active = 0;
    render();
  });

  // Capture phase on window: runs before the document-level handlers.
  window.addEventListener(
    'keydown',
    (e) => {
      if ((e.ctrlKey || e.metaKey) && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'k') {
        e.preventDefault();
        e.stopImmediatePropagation();
        setOpen(!open);
        return;
      }
      if (!open) return;
      if (e.key === 'Escape') {
        e.preventDefault();
        e.stopImmediatePropagation();
        if (mode === 'plugins') {
          mode = 'root';
          input.value = '';
          active = 0;
          render();
        } else setOpen(false);
      } else if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
        e.preventDefault();
        e.stopImmediatePropagation();
        setActive(active + (e.key === 'ArrowDown' ? 1 : -1));
      } else if (e.key === 'Enter') {
        e.preventDefault();
        e.stopImmediatePropagation();
        activate(active);
      } else if (e.key === 'Backspace' && mode === 'plugins' && !input.value) {
        e.preventDefault();
        mode = 'root';
        render();
      }
    },
    true,
  );

  scrim.addEventListener('mousedown', (e) => {
    if (!box.contains(e.target)) setOpen(false);
  });
})();
