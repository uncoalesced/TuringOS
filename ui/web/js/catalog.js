// Catalogue and DOM helpers shared by the command palette and the Bazaar.
// Mock catalogue for now: installing only flips in-memory state, but both
// views read and write the same `installed` set.
window.TuringCatalog = (() => {
  const SVGNS = 'http://www.w3.org/2000/svg';

  const PLUGINS = [
    { id: 'linear', brand: '#5E6AD2', name: 'Linear', by: 'Linear', desc: 'Create and triage issues from a prompt.', hue: 235, isNew: true, featured: true },
    { id: 'slack', brand: '#4A154B', name: 'Slack', by: 'Slack', desc: 'Read channels, draft replies, post summaries.', hue: 320, isNew: true },
    { id: 'notion', brand: '#000000', name: 'Notion', by: 'Notion', desc: 'Search pages and turn notes into tasks.', hue: 0, mono: true },
    { id: 'figma', brand: '#F24E1E', name: 'Figma', by: 'Figma', desc: 'Pull frames and design tokens into code.', hue: 12, isNew: true },
    { id: 'spotify', brand: '#1DB954', name: 'Spotify', by: 'Spotify', desc: 'Focus playlists and now-playing controls.', hue: 145 },
    { id: 'gdrive', brand: '#4285F4', name: 'Google Drive', by: 'Google', desc: 'Find, read and attach Drive files.', hue: 50 },
    { id: 'docker', brand: '#2496ED', name: 'Docker', by: 'Docker', desc: 'List, start and tail logs of containers.', hue: 205, isNew: true },
    { id: 'homeassistant', brand: '#18BCF2', name: 'Home Assistant', by: 'Open Home', desc: 'Lights, climate and scenes by voice.', hue: 195 },
  ];

  const installed = new Set(['pdf', 'slack']);

  const el = (tag, cls, text) => {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  };

  // cls null: a bare <svg>, styled by its container (the palette does this)
  const icon = (id, cls = 'icon') => {
    const svg = document.createElementNS(SVGNS, 'svg');
    if (cls) svg.setAttribute('class', cls);
    svg.setAttribute('aria-hidden', 'true');
    const use = document.createElementNS(SVGNS, 'use');
    use.setAttribute('href', `#${id}`);
    svg.append(use);
    return svg;
  };

  return { PLUGINS, installed, el, icon };
})();
