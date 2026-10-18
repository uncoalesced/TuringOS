// Engineered by uncoalesced
// Bazaar — the built-in store for skills, plugins, and MCP servers. Opens as a window inside
// the shell (the shell is fullscreen, so there's no OS window to host it).
// Connected to turingosd daemon RPC bridge with offline fallback.
(() => {
  const { PLUGINS, installed, el, icon } = window.TuringCatalog;

  const SKILLS = [
    { id: 'pdf', name: 'PDF', by: 'Anthropic', desc: 'Read, fill and merge PDFs; pull tables out of scanned docs.', hue: 8, featured: true },
    { id: 'xlsx', name: 'Spreadsheets', by: 'Anthropic', desc: 'Build and edit Excel sheets with formulas and charts.', hue: 140 },
    { id: 'pptx', name: 'Slides', by: 'Anthropic', desc: 'Turn an outline into a clean, on-brand deck.', hue: 28 },
    { id: 'frontend', name: 'Frontend Design', by: 'Anthropic', desc: 'Ship polished UI with real design taste, not defaults.', hue: 262, isNew: true },
    { id: 'webtest', name: 'Webapp Testing', by: 'Anthropic', desc: 'Drive a real browser to click through and verify your app.', hue: 200 },
    { id: 'brand', name: 'Brand Guidelines', by: 'Anthropic', desc: 'Keep colours, type and voice consistent everywhere.', hue: 18 },
    { id: 'mcp', name: 'MCP Builder', by: 'Anthropic', desc: 'Scaffold a Model Context Protocol server in minutes.', hue: 180, isNew: true },
    { id: 'skill-creator', name: 'Skill Creator', by: 'Anthropic', desc: 'Package what you do often into a reusable skill.', hue: 45 },
  ];

  const SECTIONS = [
    { id: 'discover', name: 'Discover', icon: 'ic-grid' },
    { id: 'mcp', name: 'MCP Servers', icon: 'ic-terminal' },
    { id: 'skills', name: 'Skills', icon: 'ic-zap' },
    { id: 'plugins', name: 'Plugins', icon: 'ic-package' },
    { id: 'installed', name: 'Installed', icon: 'ic-download' },
  ];
  let section = 'discover';
  let query = '';
  let isOffline = false;
  let dynamicItems = [];
  const disabledItems = new Set();
  const loadingMap = new Map(); // id -> 'installing' | 'uninstalling'

  // ─── Window chrome ────────────────────────────────────────────────────────
  const win = el('section', 'app-window bazaar');
  win.id = 'bazaar';
  win.hidden = true;
  win.setAttribute('role', 'dialog');
  win.setAttribute('aria-label', 'Bazaar');

  const titlebar = el('header', 'app-titlebar');
  const lights = el('div', 'app-lights');
  const mkLight = (kind, label, fn) => {
    const b = el('button', `app-light app-light--${kind}`);
    b.type = 'button';
    b.setAttribute('aria-label', label);
    b.addEventListener('click', (e) => { e.stopPropagation(); fn(); });
    return b;
  };
  lights.append(
    mkLight('close', 'Close', () => close({ reset: true })),
    mkLight('min', 'Minimise', () => close()),
    mkLight('zoom', 'Zoom', () => toggleZoom()),
  );
  const title = el('p', 'app-title', 'Bazaar');
  const offlineBadge = el('span', 'bz-offline-badge', '[offline catalogue]');
  offlineBadge.title = 'Serving from local 24h cache or bundled snapshot';
  offlineBadge.hidden = true;
  titlebar.append(lights, title, offlineBadge);

  const sidebar = el('nav', 'bz-sidebar');
  const brand = el('div', 'bz-brand');
  const brandTile = el('span', 'bz-brand-tile');
  brandTile.append(icon('ic-bag'));
  brand.append(brandTile, el('span', 'bz-brand-name', 'Bazaar'));
  const search = el('label', 'bz-search');
  const input = el('input');
  input.type = 'search';
  input.placeholder = 'Search';
  input.spellcheck = false;
  search.append(icon('ic-search'), input);
  const navList = el('ul', 'bz-nav');
  sidebar.append(brand, search, navList);

  const main = el('div', 'bz-main');
  const body = el('div', 'app-body');
  body.append(sidebar, main);
  win.append(titlebar, body);
  document.body.append(win);

  // ─── Daemon Synchronization ───────────────────────────────────────────────
  async function refreshBazaar() {
    if (!window.shell?.bazaarList) return;
    try {
      const activeProj = window.getActiveProject ? window.getActiveProject() : null;
      const res = await window.shell.bazaarList(activeProj?.path);
      if (res && res.ok) {
        isOffline = !!res.offline;
        offlineBadge.hidden = !isOffline;
        if (Array.isArray(res.entries)) {
          dynamicItems = res.entries.map((entry) => {
            const kind = entry.type || entry.kind || 'mcp';
            let hue = entry.hue;
            if (hue == null) {
              if (kind === 'mcp') hue = 180;
              else if (kind === 'skill') hue = 45;
              else hue = 210;
            }
            return {
              id: entry.id,
              name: entry.name || entry.id,
              desc: entry.description || entry.desc || '',
              by: entry.author || (entry.repo ? entry.repo.split('/')[0] : 'Community'),
              kind,
              hue,
              brand: entry.brand || null,
              featured: !!entry.featured,
              isNew: !!entry.isNew,
              installed: !!entry.installed,
              enabled: entry.enabled !== false,
            };
          });

          for (const item of dynamicItems) {
            if (item.installed) installed.add(item.id);
            else installed.delete(item.id);
            if (!item.enabled) disabledItems.add(item.id);
            else disabledItems.delete(item.id);
          }
          render();
        }
      }
    } catch (e) {
      console.warn('Failed to refresh bazaar from daemon:', e);
    }
  }

  function getAllItems() {
    const map = new Map();
    for (const s of SKILLS) map.set(s.id, { ...s, kind: 'skill' });
    for (const p of PLUGINS) map.set(p.id, { ...p, kind: 'plugin' });
    for (const d of dynamicItems) map.set(d.id, d);
    return Array.from(map.values());
  }

  // ─── Rendering ────────────────────────────────────────────────────────────
  function renderNav() {
    navList.replaceChildren(...SECTIONS.map((s) => {
      const li = el('li');
      const b = el('button', 'bz-nav-item');
      b.type = 'button';
      b.classList.toggle('is-active', s.id === section && !query);
      b.append(icon(s.id === 'discover' ? 'ic-grid' : s.icon), el('span', null, s.name));
      if (s.id === 'installed') b.append(el('span', 'bz-count', String(installed.size)));
      b.addEventListener('click', () => { section = s.id; query = ''; input.value = ''; render(); });
      li.append(b);
      return li;
    }));
  }

  function tile(item, kind, size = '') {
    const t = el('span', `bz-tile ${size}`);
    t.style.setProperty('--hue', item.hue);
    if (item.mono) t.classList.add('is-mono');

    if (item.brand) {
      t.classList.add('has-logo');
      t.style.setProperty('--brand', item.brand);
      const logo = el('span', 'bz-tile-logo');
      logo.style.setProperty('--logo', `url("assets/icons/brands/${item.id}.svg")`);
      t.append(logo);
      const badge = el('span', 'bz-tile-kind');
      badge.append(icon(kind === 'skill' ? 'ic-zap' : kind === 'mcp' ? 'ic-terminal' : 'ic-package'));
      t.append(badge);
      return t;
    }

    const img = el('img', 'bz-tile-img');
    img.src = `assets/icons/fluent-3d/${item.id}.png`;
    img.alt = '';
    img.draggable = false;
    img.addEventListener('error', () => img.replaceWith(el('span', 'bz-tile-letter', item.name[0])), { once: true });
    t.classList.add('has-img');
    img.addEventListener('error', () => t.classList.remove('has-img'), { once: true });
    t.append(img);
    const badge = el('span', 'bz-tile-kind');
    badge.append(icon(kind === 'skill' ? 'ic-zap' : kind === 'mcp' ? 'ic-terminal' : 'ic-package'));
    t.append(badge);
    return t;
  }

  function getButton(item) {
    const b = el('button', 'bz-get');
    b.type = 'button';
    const paint = () => {
      const loading = loadingMap.get(item.id);
      const on = installed.has(item.id);
      b.classList.toggle('is-installed', on);
      b.classList.toggle('is-loading', !!loading);
      if (loading) {
        b.replaceChildren(el('span', null, loading === 'installing' ? 'Installing…' : 'Removing…'));
        b.disabled = true;
      } else {
        b.disabled = false;
        b.replaceChildren(...(on ? [icon('ic-check'), el('span', null, 'Installed')] : [el('span', null, 'Get')]));
        b.setAttribute('aria-label', `${on ? 'Remove' : 'Get'} ${item.name}`);
      }
    };
    paint();
    b.addEventListener('click', async (e) => {
      e.stopPropagation();
      const on = installed.has(item.id);
      if (window.shell?.bazaarInstall && window.shell?.bazaarUninstall) {
        loadingMap.set(item.id, on ? 'uninstalling' : 'installing');
        paint();
        try {
          if (on) {
            await window.shell.bazaarUninstall(item.id);
            installed.delete(item.id);
            disabledItems.delete(item.id);
          } else {
            await window.shell.bazaarInstall(item.id);
            installed.add(item.id);
          }
        } catch (err) {
          console.error('Bazaar install error:', err);
        } finally {
          loadingMap.delete(item.id);
          await refreshBazaar();
        }
      } else {
        if (installed.has(item.id)) installed.delete(item.id);
        else installed.add(item.id);
        paint();
        renderNav();
        if (section === 'installed') renderMain();
      }
    });
    return b;
  }

  function card(item, kind, i) {
    const c = el('article', 'bz-card');
    c.style.setProperty('--i', i);
    const text = el('div', 'bz-card-text');
    const name = el('p', 'bz-card-name', item.name);
    if (item.isNew && !installed.has(item.id)) name.append(el('span', 'bz-new', 'New'));
    const isMcp = (item.kind || kind) === 'mcp';
    const kindLabel = isMcp ? 'MCP Server' : (kind === 'skill' ? 'Skill' : 'Plugin');
    text.append(name, el('p', 'bz-card-desc', item.desc), el('p', 'bz-card-by', `${kindLabel} · ${item.by}`));

    const actions = el('div', 'bz-card-actions');
    const activeProj = window.getActiveProject ? window.getActiveProject() : null;
    if (installed.has(item.id) && activeProj && window.shell?.bazaarSetRule) {
      const isDisabled = disabledItems.has(item.id);
      const toggle = el('button', `bz-rule-toggle ${isDisabled ? 'is-disabled' : 'is-enabled'}`);
      toggle.type = 'button';
      toggle.title = `${isDisabled ? 'Enable' : 'Disable'} in ${activeProj.name}`;
      toggle.append(
        icon(isDisabled ? 'ic-x' : 'ic-check'),
        el('span', null, isDisabled ? 'Disabled' : 'Active')
      );
      toggle.addEventListener('click', async (e) => {
        e.stopPropagation();
        toggle.disabled = true;
        const willEnable = isDisabled;
        try {
          await window.shell.bazaarSetRule(activeProj.path, item.id, willEnable);
          if (willEnable) disabledItems.delete(item.id);
          else disabledItems.add(item.id);
          render();
        } catch (err) {
          console.error('Failed to set project rule:', err);
        } finally {
          toggle.disabled = false;
        }
      });
      actions.append(toggle);
    }
    actions.append(getButton(item));

    c.append(tile(item, item.kind || kind), text, actions);
    return c;
  }

  function grid(items, kind) {
    const g = el('div', 'bz-grid');
    g.append(...items.map((it, i) => card(it, it.kind || kind, i)));
    return g;
  }

  function header(text, sub) {
    const h = el('header', 'bz-head');
    h.append(el('h2', null, text));
    if (sub) h.append(el('p', null, sub));
    return h;
  }

  function hero(item, kind) {
    const h = el('div', 'bz-hero');
    h.style.setProperty('--hue', item.hue);
    const text = el('div', 'bz-hero-text');
    const label = kind === 'skill' ? 'Featured skill' : kind === 'mcp' ? 'Featured MCP Server' : 'Featured plugin';
    text.append(
      el('p', 'bz-hero-eyebrow', label),
      el('h3', null, item.name),
      el('p', 'bz-hero-desc', item.desc),
    );
    const cta = getButton(item);
    cta.classList.add('bz-get--hero');
    text.append(cta);
    h.append(text, tile(item, kind, 'bz-tile--xl'));
    return h;
  }

  function renderMain() {
    const all = getAllItems();
    const q = query.trim().toLowerCase();
    const nodes = [];

    if (q) {
      const hits = all.filter((x) => `${x.name} ${x.desc} ${x.by}`.toLowerCase().includes(q));
      nodes.push(header(`Results for “${query.trim()}”`, `${hits.length} found`));
      nodes.push(hits.length ? grid(hits) : el('p', 'bz-empty', 'Nothing matches that yet.'));
    } else if (section === 'discover') {
      nodes.push(header('Discover', 'Teach Claude new tricks, install MCP servers, and connect tools.'));
      const skillsList = all.filter((x) => x.kind === 'skill');
      const pluginsList = all.filter((x) => x.kind === 'plugin');
      const mcpList = all.filter((x) => x.kind === 'mcp');

      const featSkill = skillsList.find((s) => s.featured) || skillsList[0];
      const featMcp = mcpList.find((m) => m.featured) || mcpList[0];
      const featPlugin = pluginsList.find((p) => p.featured) || pluginsList[0];

      const heroes = el('div', 'bz-heroes');
      if (featSkill) heroes.append(hero(featSkill, 'skill'));
      if (featMcp) heroes.append(hero(featMcp, 'mcp'));
      else if (featPlugin) heroes.append(hero(featPlugin, 'plugin'));
      nodes.push(heroes);

      if (mcpList.length) {
        nodes.push(header('Model Context Protocol (MCP)'), grid(mcpList.slice(0, 4), 'mcp'));
      }
      nodes.push(header('New plugins'), grid(pluginsList.filter((p) => p.isNew).slice(0, 4), 'plugin'));
      nodes.push(header('Popular skills'), grid(skillsList.slice(0, 4), 'skill'));
    } else if (section === 'mcp') {
      const mcps = all.filter((x) => x.kind === 'mcp');
      nodes.push(header('MCP Servers', 'Model Context Protocol servers that give Claude external tools.'), grid(mcps, 'mcp'));
    } else if (section === 'skills') {
      const skills = all.filter((x) => x.kind === 'skill');
      nodes.push(header('Skills', 'Know-how Claude loads when a task calls for it.'), grid(skills, 'skill'));
    } else if (section === 'plugins') {
      const plugins = all.filter((x) => x.kind === 'plugin');
      nodes.push(header('Plugins', 'Connect Claude to the apps you already use.'), grid(plugins, 'plugin'));
    } else {
      const mine = all.filter((x) => installed.has(x.id));
      const activeProj = window.getActiveProject ? window.getActiveProject() : null;
      let sub = `${mine.length} installed on this machine`;
      if (activeProj) sub += ` · Active repo: ${activeProj.name}`;
      nodes.push(header('Installed', sub));
      nodes.push(mine.length ? grid(mine) : el('p', 'bz-empty', 'Nothing installed yet — grab something from Discover or MCP.'));
    }
    main.replaceChildren(...nodes);
    main.scrollTop = 0;
  }

  function render() {
    renderNav();
    renderMain();
  }

  input.addEventListener('input', () => { query = input.value; render(); });

  // ─── Open / close / zoom / drag ───────────────────────────────────────────
  let isOpen = false;
  let closeTimer = null;
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');

  function open() {
    clearTimeout(closeTimer);
    if (isOpen) { input.focus(); return; }
    isOpen = true;
    render();
    refreshBazaar();
    win.hidden = false;
    win.classList.remove('is-closing');
    win.classList.add('is-opening');
    void win.offsetWidth;
    win.classList.remove('is-opening');
    setTimeout(() => input.focus(), 60);
  }

  function close({ reset = false } = {}) {
    if (!isOpen) return;
    isOpen = false;
    win.classList.add('is-closing');
    closeTimer = setTimeout(() => {
      win.hidden = true;
      win.classList.remove('is-closing');
      if (reset) {
        section = 'discover';
        query = '';
        input.value = '';
        dx = 0;
        dy = 0;
        applyOffset();
        win.classList.remove('is-zoomed');
      }
    }, reduced.matches ? 0 : 240);
  }

  function toggleZoom() {
    win.classList.toggle('is-zoomed');
    if (win.classList.contains('is-zoomed')) { dx = 0; dy = 0; applyOffset(); }
  }

  let dx = 0;
  let dy = 0;
  const applyOffset = () => {
    win.style.setProperty('--dx', `${dx}px`);
    win.style.setProperty('--dy', `${dy}px`);
  };
  titlebar.addEventListener('pointerdown', (e) => {
    if (e.button !== 0 || e.target.closest('button') || win.classList.contains('is-zoomed')) return;
    titlebar.setPointerCapture(e.pointerId);
    const sx = e.clientX - dx;
    const sy = e.clientY - dy;
    win.classList.add('is-dragging');
    const move = (ev) => {
      dx = ev.clientX - sx;
      const r = win.getBoundingClientRect();
      const baseTop = r.top - dy;
      dy = Math.min(Math.max(ev.clientY - sy, 44 - baseTop), innerHeight - 60 - baseTop);
      applyOffset();
    };
    const up = () => {
      win.classList.remove('is-dragging');
      titlebar.removeEventListener('pointermove', move);
    };
    titlebar.addEventListener('pointermove', move);
    titlebar.addEventListener('pointerup', up, { once: true });
    titlebar.addEventListener('pointercancel', up, { once: true });
  });
  titlebar.addEventListener('dblclick', (e) => { if (!e.target.closest('button')) toggleZoom(); });

  document.addEventListener('keydown', (e) => {
    if (!isOpen) return;
    if (e.key === 'Escape' && !document.querySelector('.palette-scrim:not([hidden])')) {
      if (input.value) { input.value = ''; query = ''; render(); } else close();
    }
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'w') { e.preventDefault(); close({ reset: true }); }
  });

  window.openBazaar = (where) => {
    if (where) { section = where; query = ''; input.value = ''; }
    open();
  };

  // Initial silent background refresh if shell is available
  if (window.shell?.bazaarList) {
    refreshBazaar();
  }
})();
