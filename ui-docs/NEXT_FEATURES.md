# Next three features: plan

**Status: all five pieces below are built** (Finder Option A, side panel
shell, GitHub widget, Gmail/Calendar OAuth widget, Clawd). The Status table
in `ui-docs/UI_SHELL.md` has a one-line summary of each, and its new §9
lists the exact `~/.turingos/config.env` keys the project owner needs to set:
`ANTHROPIC_API_KEY` for Clawd, `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` for
Calendar. The Google keys need a real Google Cloud OAuth "Desktop app"
client registered first, which can't be done from inside this repo. The
rest of this document is left as written, as a record of what we planned
and why.

This is a research doc, not a spec. It came out of a planning pass over the
codebase before any of this was built. Two facts shape every section below,
and both were confirmed by reading the code, not assumed:

1. **The renderer can't touch the network at all.** `ui/web/index.html`'s CSP
   (`default-src 'self'`) and `ui/preload.js`'s five exposed methods
   (`getState`, `onState`, `listProjects`, `startAgent`, `launchApp`) mean
   every new network call (Anthropic, `gh`, Google) has to live in
   `ui/main.js` and cross the bridge only as already-shaped data.
2. **`./turingos ui` doesn't get you `~/.turingos/config.env` for free.**
   We confirmed this by reading `turingos` and `core/config.sh`: `config.sh`
   *is* sourced for every subcommand, `ui` included, but `config::load()`
   does a plain `source` with no `export`/`set -a`, and `config::set()`
   writes the file as plain `KEY=VALUE` lines (no `export` keyword). Values
   loaded that way are only unexported shell variables in that bash
   process, and the `ui)` case immediately does `exec ui/run.sh`, which
   only inherits real environment variables. A key like `ANTHROPIC_API_KEY`
   in `config.env` will **not** reach `ui/main.js`'s `process.env` this
   way, so `ui/main.js` has to parse the file itself.

---

## 1. "Clawd" desktop pet

A small blocky mascot (Space-Invader silhouette, two square eyes, two
leg/arm nubs) that idles or patrols near the dock, walks with alternating
legs, and opens a small Q&A popover on click. Claude Haiku answers.

**Chat is single-shot, not multi-turn.** One question in, one answer back,
and no conversation history is kept anywhere (renderer or main process).
The popover shows the current question and its answer and replaces both on
each new question. Think mini-oracle, not persistent thread. The first pass
proposed rolling chat history; we dropped it because nobody asked for it,
and without it the IPC contract is simpler and the cost/rate-limit story is
easier (there's no growing context to bound).

**Sprite:** there's no mascot asset anywhere in the repo yet. Build it from
scratch as plain HTML/CSS (nested `div`s), not a flat SVG symbol, because
the walk cycle needs legs that animate independently. Reuse `corner-shape:
squircle` (already proven on `.dock`/`.dock-item`) for the body, `var(--bg)`
squares for the eyes (a negative-space cutout, no new asset), and leg
rectangles animated with `rotate()` keyframes. That's transform-only, which
matches this codebase's motion rules (no opacity). `prefers-reduced-motion`
already kills all animations globally, so we get that for free as long as
this stays CSS-driven. Patrol with `translateX`/`scaleX(±1)` on a fixed
wrapper, modelled on the dock magnify `requestAnimationFrame` loop in
`ui/app.js`.

**Placement:** stay clear of `.dock-edge`'s 8px hover strip and the dock's
own ~240px centered footprint. A lane in a bottom corner (e.g. the last
~160px of one side, at the 960px minimum window width), with the sprite's
baseline at `bottom: 46-56px`, clears both the edge strip and the corner
status text (`bottom: 18px`). Put its z-index below the dock's stack
(dock-edge 25 / dock 26 / dock-error 27 / dock-tooltip 28) so the dock
always wins if someone misjudges a lane later.

**Chat popover:** copy `setWeatherOpen()`'s dissolve pattern (`hidden` +
`.is-closing` + a matching `setTimeout`) and `.weather-card`'s pop-in/pop-out
with an anchored `transform-origin`. Reuse the composer's send-button icon
for the input row.

**IPC (single message → single response):**
```js
// preload.js
askClawd: (message) => ipcRenderer.invoke('clawd:ask', { message })

// main.js
ipcMain.handle('clawd:ask', async (_e, { message }) => {
  if (typeof message !== 'string' || !message.trim())
    return { ok: false, error: 'Say something first.' };
  const key = getAnthropicKey();
  if (!key) return { ok: false, error: 'Clawd needs an API key — set ANTHROPIC_API_KEY in ~/.turingos/config.env.' };
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
Model: `claude-haiku-4-5`. `max_tokens: 512` caps the cost of each turn.
Each request is independent, so there's no history growing over a session.
Disable send while a request is in flight. Add an optional
`TURINGOS_CLAWD=off` switch to match `TURINGOS_WEATHER=off`.

**API key storage:** `ANTHROPIC_API_KEY` goes in `~/.turingos/config.env`
and is read by a new `readConfigEnv()` helper in `main.js`, a plain
`KEY=VALUE` parser (see point 2 above for why `process.env` alone isn't
enough). Precedence: a real `process.env.ANTHROPIC_API_KEY` first, for
anyone who exported it before launching, then the parsed file. **Never**
add a getter for the key to `preload.js`. It must never reach the renderer.

**Open questions:**
- Is "Clawd" the pet separate from "Clawd Bazaar" (the MCP tool marketplace
  in `plan.md`)? Confirmed separate. They share the pun and nothing else;
  there's no architecture overlap.
- Any animation states beyond walk/idle (a reaction on click, a "sleeping"
  state late at night)?
- Bare Q&A, or should it get read-only awareness of the app's own state
  (agent status, sandbox) through the existing `snapshot()`? We recommend
  bare Q&A for v1. Awareness would grow the scope, so it's a v2 item.
- Always on, or can the user dismiss it?

---

## 2. Gmail + GitHub in the widgets panel

`ui-docs/UI_SHELL.md` already lists a side panel (Ctrl/⌘+J) with
Calendar/GitHub/etc. under "not built yet", but none of it exists: no panel
markup, and no keybinding besides the existing Ctrl/⌘+K composer focus.
That makes this two builds: the panel shell, and two data sources behind
it, one easy and one hard.

**Panel shell (needed either way):** a right-edge `<aside>` that slides in
via `translateX(100%→ 0)`, with the same translucent blur as the menu
bar and dock. The toggle function follows the shape of `setWeatherOpen()`.
Wire both Ctrl/⌘+J and "click the clock" to it.

**GitHub is easy and needs no new credentials.** `UI_SHELL.md` already
specs the exact commands, assuming `gh auth login` has been run on the demo
machine: `gh pr list --author @me --json ...` and
`gh search prs --review-requested=@me --state open --json ...`. Wrap `gh`
with the same `execFile` pattern we use for `nmcli`, cache the parsed
result in a module-level variable, and refresh it on its own multi-minute
interval. Not on the 2s poll: this hits GitHub's real API. Add it to
`snapshot()`, and fall back to `null`/sample data the way weather does when
the CLI or auth isn't available.

**Gmail/Calendar is hard: real OAuth.** This is the first feature that
touches real third-party personal data, which is a much bigger trust
surface than anything shipped so far (weather uses IP geolocation, and
agent/sandbox state is local). The approach we recommend, checked against
`google-auth-library`'s own documented pattern, is the standard desktop
"installed app" flow: `OAuth2Client.generateAuthUrl()` for the consent URL,
a temporary loopback HTTP server (`127.0.0.1`, OS-assigned port) to catch
the redirect, then exchange the code for tokens. **Open the consent URL in
the system's default browser, not an in-app BrowserWindow.** Google rejects
or flags OAuth inside embedded webviews for this client type. To open it,
reuse the existing `commandExists`/`spawn` fallback chain, the same one
behind the dock's "Browser" launcher.

Add only `google-auth-library` (not the full `googleapis` SDK) and call
`googleapis.com/calendar/v3/...` with plain `fetch()`. Weather already
prefers raw fetch over an SDK, so this matches.

**Credentials:** `GOOGLE_CLIENT_ID`/`GOOGLE_CLIENT_SECRET` go in
`~/.turingos/config.env` (same `readConfigEnv()` helper as the Anthropic
key). The refresh token goes in a new `~/.turingos/google-tokens.json`,
mode `0o600`, and is never exposed to the renderer. Only derived display
fields (event title/time) cross the bridge. Keep the scope minimal:
`calendar.events.readonly` only, unless someone explicitly confirms they
want an inbox summary. Gmail read access is a much bigger ask than calendar
read access, and we shouldn't request it on speculation.

**Mock mode:** the weather/agent sample data exists so the desktop "reads
as intended" when nothing is configured. Calendar should be different: show
an honest "Connect Google to see your next meeting" empty state when
disconnected, not a believable fake event. This is real personal data, and
a fake calendar entry could mislead someone watching a demo who asks
whether it's real.

**Open questions:**
- Exact Gmail scope: next calendar event only, or an inbox summary too?
  Decide before registering OAuth scopes.
- Which GitHub views for v1: both "My PRs" and "Review Requests" as
  already specced, or fewer?
- Where does "Disconnect Google" go? There's no in-app Settings screen
  yet (the dock's Settings icon launches the real OS settings app).
- Refresh cadence and a manual refresh control, given that both `gh` and
  Google Calendar have real rate limits.

---

## 3. "Finder": needs your decision before anything gets built

There are two real options, and they differ a lot in scope. We're flagging
both instead of guessing which one you meant.

**Option A: it may already exist.** The dock's "Files" icon already
launches a real external file manager (`xdg-open $HOME`, falling back to
`dolphin`) through the existing `dock:launch` handler. The base is Debian +
KDE, so `dolphin` is already the right native fallback. Effort: minutes.
At most, widen the fallback chain (`nautilus`, `pcmanfm`, `nemo`,
`thunar`) for non-KDE installs, and confirm the window actually shows up
under `KIOSK=1` fullscreen mode. Kiosk strips window chrome, so test this
before relying on it for the demo.

**Option B: a real in-app Finder.** This is new scope. Every surface in the
app today is a floating overlay on a single fixed desktop view; there's no
"app window" or multi-view concept yet. Building it means inventing an
app-shell pattern and a new directory-read IPC contract. It also needs a
security scope for what's browsable, and that part is a real decision, not
just engineering. The existing project scanner only ever surfaces git-repo
folder *names*, but a Finder exposes arbitrary paths across the system
unless we deliberately fence it to e.g. `$HOME`. Effort: substantial, on
par with the Gmail OAuth build or larger, because it also means inventing
a UI paradigm this codebase has no precedent for.

**Recommendation:** ship A now (it costs almost nothing and already works),
and treat B as a separate future project that only happens if you decide
it's worth it. A demo audience is unlikely to tell a real KDE file manager
from a custom one unless someone tells them.

**Blocking question:** confirm and polish the existing Files launcher (A),
or commit to a real in-app file browser (B)?

---

## Suggested build order (cheapest → most expensive)

1. **Finder Option A**: minutes. Widen the fallback chain and test under kiosk mode.
2. **Side panel shell**: needed before either widget. Self-contained, no new credentials.
3. **GitHub widget**: small once the shell exists. No new credentials.
4. **Clawd pet**: moderate. The sprite and patrol are a bounded frontend chunk, and the Haiku call and popover both closely follow existing patterns.
5. **Gmail/Calendar OAuth**: the largest and riskiest. It adds a new dependency, a new class of credential, a new auth flow, and the most privacy and product decisions. It needs your sign-off on the Google Cloud OAuth app registration before we write code.
6. **Finder Option B**: only if you pick it over A after seeing A in action.

## Files this touches

- `ui/main.js`: every new IPC handler (`clawd:ask`, GitHub refresh, Google OAuth + token storage), the new `readConfigEnv()` helper, new `snapshot()` fields
- `ui/preload.js`: new bridge methods only (`askClawd`, panel/widget getters), never raw keys or tokens
- `ui/app.js`: patterns to copy: `setWeatherOpen()`, the dock's magnify `requestAnimationFrame` loop, the `SAMPLE`/`snap.live` fallback convention
- `ui/styles.css`: motion tokens, `corner-shape: squircle`, and the existing z-index/positioning to design around
- `ui-docs/UI_SHELL.md`: the target spec this should stay consistent with
- `core/config.sh`: the `~/.turingos/config.env` convention we're reusing, and the source of the config-bypass problem above

---

## Follow-ups from the refactor (October 2026)

Deliberately left for later, so they don't get lost:

- **Dock: Debian apps drawer.** The dock's Files and Settings buttons still
  try KDE apps first (`dolphin`, `systemsettings`), which the ISO doesn't
  ship. Plan: a drawer of the apps the ISO does have (Thunar, xterm,
  NetworkManager settings), auto-listed from their `.desktop` files.
- **Packages the dock and widgets assume:** a web browser (the Browser button
  and Google sign-in both go through `xdg-open`), `gh` (GitHub widget), and
  a notification daemon such as `dunst` (`notify-send` does nothing
  without one). Each grows the ISO; decide per item.
- **Wispr Flow:** the voice backend uses the unofficial `wisprflow-re`
  client with a session copied from another machine. Switch to an official
  client or API if Wispr ships one for Linux.
- **Effort for agent runs:** the model picker's effort is used for chat
  answers only; `agent/claude.sh` passes the model, not the effort.
