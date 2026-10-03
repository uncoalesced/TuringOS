// Shared helpers, sample data and cross-module state. Loaded first.
// Opened in a plain browser (no backend), the shell falls back to sample data.

const $ = (sel) => document.querySelector(sel);
const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');

const SAMPLE = {
  live: false,
  agent: { running: true, task: 'Refactor the auth module and run the tests' },
  sandbox: 'task-1727340000',
  gameMode: false,
  system: { host: 'turingos', cpu: 18, mem: 42, battery: { level: 82, charging: false }, wifi: { ssid: 'Studio' } },
  weather: { city: 'Bengaluru', temp: 26, feels: 30, rain: 0, wind: 8, windDir: 200, code: 2, day: true },
  github: {
    mine: [{ number: 127, title: 'Handle an interrupted apt install', url: '#' }],
    reviews: [{ number: 89, title: 'Add Btrfs snapshot rollback', repository: { name: 'turingos' }, url: '#' }],
  },
  // Real personal data, not made up — unlike weather/agent sample data
  // (meant to make the desktop read as intended), a fake meeting here could
  // mislead someone watching a demo who asks if it's real. Always show the
  // honest disconnected state until a real Google account is connected.
  calendar: { connected: false, nextEvent: null },
  user: { name: null },
};

const SAMPLE_PROJECTS = [
  { name: 'turingos', path: '~/code/turingos' },
  { name: 'auth-service', path: '~/code/auth-service' },
  { name: 'dotfiles', path: '~/dotfiles' },
];

let lastSnap = null;
let userName = null;
let pendingStart = false;
let pendingStartTimer = null;
let lastAgentRunning = false;
let lastAgentTask = '';
