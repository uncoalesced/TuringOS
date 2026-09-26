# Next three features — plan

Research doc, not a spec — written by a planning pass over the current
codebase before any of this is built. Two load-bearing facts shape every
section below, both confirmed by reading the actual code (not assumed):

1. **The renderer can't touch the network at all.** `ui/index.html`'s CSP
   (`default-src 'self'`) and `ui/preload.js`'s five exposed methods
   (`getState`, `onState`, `listProjects`, `startAgent`, `launchApp`) mean
   every new network call — Anthropic, `gh`, Google — has to live in
   `ui/main.js` and cross the bridge only as already-shaped data.
2. **`./claudeos ui` doesn't get you `~/.claudeos/config.env` for free.**
   Confirmed by reading `claudeos` and `core/config.sh` directly: `config.sh`
   *is* sourced for every subcommand including `ui`, but `config::load()`
   does a plain `source` with no `export`/`set -a`, and the file itself is
   written as plain `KEY=VALUE` (no `export` keyword) by `config::set()`.
   So values loaded that way exist only as unexported shell variables in
   that bash process — and the `ui)` case immediately does
   `exec ui/run.sh`, which only inherits real environment variables. A key
   like `ANTHROPIC_API_KEY` sitting in `config.env` will **not** reach
   `ui/main.js`'s `process.env` this way. `ui/main.js` needs to parse that
   file itself.

---

## 1. "Clawd" desktop pet

A small blocky mascot (Space-Invader silhouette, two square eyes, two
leg/arm nubs) that idles/patrols near the dock, walks with alternating
legs, and opens a small Q&A popover on click, answered by Claude Haiku.

**Chat is single-shot, not multi-turn** — one question in, one answer back,
no conversation history kept anywhere (renderer or main process). The
popover just shows the current question and its answer, replacing on each
new question — a mini-oracle widget, not a persistent thread. This was
corrected after the first pass, which had proposed rolling chat history;
dropped since it wasn't asked for and it simplifies both the IPC contract
and the cost/rate-limit story (no accumulating context to bound).

**Sprite:** no mascot asset exists yet anywhere in the repo — build it from
scratch as plain HTML/CSS (nested `div`s), not a flat SVG symbol, since the
walk cycle needs independently-animatable legs. Reuse `corner-shape:
squircle` (already proven on `.dock`/`.dock-item`) for the body, `var(--bg)`
squares for eyes (negative-space cutout, no new asset), and leg rectangles
animated via `rotate()` keyframes — transform-only, matches this codebase's
motion rules (no opacity; `prefers-reduced-motion` already nukes all
animations globally, so that's free as long as this stays CSS-driven).
Patrol via `translateX`/`scaleX(±1)` on a fixed wrapper, styled like the
existing dock magnify `requestAnimationFrame` loop in `ui/app.js`.

**Placement:** stay clear of `.dock-edge`'s 8px hover strip and the dock's
own ~240px centered footprint. A lane in a bottom corner (e.g. the last
~160px of one side, at the 960px minimum window width) with the sprite's
own baseline at `bottom: 46-56px` clears both the edge strip and the
corner status text (`bottom: 18px`). Z-index below the dock's stack
(dock-edge 25 / dock 26 / dock-error 27 / dock-tooltip 28) so the dock
always wins if a lane is ever misjudged later.

**Chat popover:** clone `setWeatherOpen()`'s dissolve pattern (`hidden` +
`.is-closing` + matching `setTimeout`) and `.weather-card`'s pop-in/pop-out
+ anchored `transform-origin`. Reuse the composer's existing send-button
icon for the input row.

**IPC (single message → single response):**
```js
// preload.js
askClawd: (message) => ipcRenderer.invoke('clawd:ask', { message })

// main.js
ipcMain.handle('clawd:ask', async (_e, { message }) => {
  if (typeof message !== 'string' || !message.trim())
    return { ok: false, error: 'Say something first.' };
  const key = getAnthropicKey();
  if (!key) return { ok: false, error: 'Clawd needs an API key — set ANTHROPIC_API_KEY in ~/.claudeos/config.env.' };
  try {
    const res = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': key, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify({
        model: 'claude-haiku-4-5', max_tokens: 512,
        system: CLAWD_SYSTEM_PROMPT,
        messages: [{ role: 'user', content: message.trim() }],
      }),
      signal: AbortSignal.timeout(15000),
    });
    if (res.status === 401) return { ok: false, error: "Clawd's API key looks wrong." };
    if (res.status === 429) return { ok: false, error: 'Clawd is popular right now — try again shortly.' };
    if (!res.ok) return { ok: false, error: `Clawd hit an error (${res.status}).` };
    const data = await res.json();
    return { ok: true, text: data.content?.find((b) => b.type === 'text')?.text || '' };
  } catch { return { ok: false, error: 'Clawd is offline right now.' }; }
});
```
Model: `claude-haiku-4-5`. `max_tokens: 512` bounds cost per turn (no
history to bound growth over a session, since each request is independent).
Disable send while a request is in flight. Optional `CLAUDEOS_CLAWD=off`
switch, matching `CLAUDEOS_WEATHER=off`.

**API key storage:** `ANTHROPIC_API_KEY` in `~/.claudeos/config.env`,
read by a new `readConfigEnv()` helper in `main.js` (plain `KEY=VALUE`
parser — see gotcha #2 above for why `process.env` alone isn't enough).
Precedence: real `process.env.ANTHROPIC_API_KEY` first (covers anyone who
exported it before launching), then the parsed file. **Never** add a
getter for the key to `preload.js` — it must never reach the renderer.

**Open questions:**
- Confirm "Clawd" the pet is a distinct thing from "Clawd Bazaar" (the MCP
  tool marketplace in `plan.md`) — confirmed separate, they just share the
  branding pun; no architecture overlap.
- Any animation states beyond walk/idle (a reaction on click, a "sleeping"
  state late at night)?
- Bare Q&A, or should it get read-only awareness of the app's own state
  (agent status, sandbox) via the existing `snapshot()`? Recommend bare
  Q&A for v1; awareness is a v2 scope increase.
- Always-on, or user-dismissible?

---

## 2. Gmail + GitHub in the widgets panel

`ui-docs/UI_SHELL.md` already speculatively lists a side panel (Ctrl/⌘+J)
with Calendar/GitHub/etc. under "not built yet" — none of it exists: no
panel markup, no keybinding beyond the existing Ctrl/⌘+K composer focus.
This is two builds: the panel shell itself, and two data sources of very
different difficulty behind it.

**Panel shell (needed either way):** a right-edge `<aside>`, sliding in via
`translateX(100%→ 0)`, same translucent blur treatment as the menu
bar/dock. Toggle function shaped like `setWeatherOpen()`. Wire Ctrl/⌘+J
and "click the clock" into it.

**GitHub — easy, no new credentials.** `UI_SHELL.md` already specs the
exact commands, assuming `gh auth login` is already done on the demo
machine: `gh pr list --author @me --json ...` and
`gh search prs --review-requested=@me --state open --json ...`. Wrap `gh`
with the existing `execFile` pattern already used for `nmcli`, cache the
parsed result in a module-level var, refresh on its own multi-minute
interval (not every 2s poll — this hits GitHub's real API), add it to
`snapshot()`, fall back to `null`/sample data the same way weather does
when the CLI or auth isn't available.

**Gmail/Calendar — hard, real OAuth.** This is the first feature that
touches real third-party personal data — a materially bigger trust surface
than anything shipped so far (weather is IP-geolocation, agent/sandbox
state is local). Recommended approach, checked against
`google-auth-library`'s own documented pattern: the standard desktop
"installed app" flow — `OAuth2Client.generateAuthUrl()` for the consent
URL, a temporary loopback HTTP server (`127.0.0.1`, OS-assigned port) to
catch the redirect, then exchange the code for tokens. **Open the consent
URL in the system's default browser, not an in-app BrowserWindow** — Google
actively rejects/flags OAuth run inside embedded webviews for this client
type. Reuse the existing `commandExists`/`spawn` fallback chain (the same
one behind the dock's own "Browser" launcher) to open it.

Add only `google-auth-library` (not the full `googleapis` SDK) and hit
`googleapis.com/calendar/v3/...` with plain `fetch()`, matching how weather
already prefers raw fetch over an SDK.

**Credentials:** `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` in
`~/.claudeos/config.env` (same `readConfigEnv()` helper as the Anthropic
key). The resulting refresh token goes in a new `~/.claudeos/google-tokens.json`,
mode `0o600`, never exposed to the renderer — only derived display fields
(event title/time) cross the bridge. Scope minimally:
`calendar.events.readonly` only, unless an inbox summary is explicitly
confirmed as wanted — Gmail read access is a much bigger ask than calendar
read access and shouldn't be requested speculatively.

**Mock mode:** unlike weather/agent sample data (meant to make the desktop
"read as intended" when nothing's configured), recommend an honest
"Connect Google to see your next meeting" empty state when disconnected,
not a believable fake event — this is real personal data, and a fake
calendar entry risks actively misleading someone watching a demo who asks
if it's real.

**Open questions:**
- Exact Gmail scope: next calendar event only, or an inbox summary too?
  Decide before registering OAuth scopes.
- Which GitHub views for v1 — both "My PRs" and "Review Requests" as
  already specced, or narrower?
- Where does "Disconnect Google" live? There's no Settings screen in-app
  yet (the dock's Settings icon just launches the real OS settings app).
- Refresh cadence / manual refresh control, given both `gh` and Google
  Calendar have real rate limits.

---

## 3. "Finder" — needs your decision before anything gets built

Two real options, genuinely different in scope. Flagging both rather than
guessing which you meant:

**Option A — it may already exist.** The dock's "Files" icon already
launches a real external file manager (`xdg-open $HOME`, falling back to
`dolphin`) through the existing `dock:launch` handler. Since the base is
Debian + KDE, `dolphin` is already the right native fallback. Effort:
minutes — at most widen the fallback chain (`nautilus`, `pcmanfm`, `nemo`,
`thunar`) for non-KDE installs, and confirm it actually surfaces visibly
under `KIOSK=1` fullscreen mode (kiosk strips window chrome, worth testing
before relying on it for the demo).

**Option B — a genuine in-app Finder.** Real net-new scope. Every surface
in the app today is a floating overlay over one single fixed desktop view
— there's no "app window"/multi-view concept anywhere yet. Building this
means inventing: an app-shell pattern that doesn't exist yet, a new
directory-read IPC contract, and — the part that actually needs a real
decision, not just engineering — a security scope for what's browsable
(unlike the existing project scanner, which only ever surfaces git-repo
folder *names*, a Finder exposes arbitrary paths system-wide unless
deliberately fenced to e.g. `$HOME` only). Effort: substantial, comparable
to or larger than the Gmail OAuth build, since it's also inventing a UI
paradigm this codebase has zero precedent for.

**Recommendation:** ship A now (near-zero cost, functionally already
there), treat B as a separate future project gated on you deciding it's
worth it — a demo audience is unlikely to tell "real KDE file manager"
from "custom one" unless told.

**Blocking question:** confirm/polish the existing Files launcher (A), or
commit to a real in-app file browser (B)?

---

## Suggested build order (cheapest → most expensive)

1. **Finder Option A** — minutes; widen the fallback chain, test under kiosk mode.
2. **Side panel shell** — needed before either widget, self-contained, no new credentials.
3. **GitHub widget** — small once the shell exists; no new credentials.
4. **Clawd pet** — moderate; sprite/patrol is a bounded frontend chunk, the Haiku call and popover both closely mirror existing patterns.
5. **Gmail/Calendar OAuth** — largest and riskiest: new dependency, a new credential class, a new auth flow, the biggest privacy/product-decision surface. Needs your sign-off on the actual Google Cloud OAuth app registration before code gets written.
6. **Finder Option B** — only if you pick it over A after seeing A in action.

## Files this touches

- `ui/main.js` — every new IPC handler (`clawd:ask`, GitHub refresh, Google OAuth + token storage), the new `readConfigEnv()` helper, new `snapshot()` fields
- `ui/preload.js` — new bridge methods only (`askClawd`, panel/widget getters) — never raw keys/tokens
- `ui/app.js` — patterns to clone: `setWeatherOpen()`, the dock's magnify `requestAnimationFrame` loop, the `SAMPLE`/`snap.live` fallback convention
- `ui/styles.css` — motion tokens, `corner-shape: squircle`, existing z-index/positioning to design around
- `ui-docs/UI_SHELL.md` — the target spec this should stay consistent with
- `core/config.sh` — the `~/.claudeos/config.env` convention being reused, and the source of the config-bypass gotcha above
