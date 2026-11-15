# ui-shell

The desktop shell of TuringOS: a menu bar, a clock and a prompt box in the
middle, a dock, a side panel with widgets, a command palette and a store
window for the Bazaar. It is a web page (`ui/web`) that `turingos-bridged-ws`
serves to a Brave app window. A Rust service, `turingosd` (`daemon/`), does
everything the page can't: reading `~/.turingos`, starting agents, calling out
to the network.

The code and the CLI are still called `turingos`. "TuringOS" is the name on
screen.

## Status

What works in v1.3:

| Area | What it does |
|---|---|
| Menu bar | TuringOS brand mark and name, Wi-Fi, battery, light/dark toggle, date and time. The clock and the Wi-Fi icon open the side panel. |
| Desktop | Clock, greeting with the user's first name, and the composer ("What do you want to cook?"). |
| Composer, task | Type `@` or `+` to pick a project (git repos found by the daemon). Enter runs `turingos agent start <project> <task>`. `agent_start` only accepts paths that the project list returned. |
| Composer, question | A message with no project attached is a plain question, answered inline with one Claude call. No sandbox, no agent. Attaching a project is what makes it a Claude Code task. |
| Model picker | Fable 5.1, Opus 5.5, Sonnet 5.5 or Haiku 4.5, plus an effort level (Low, Medium, High, Extra, Max). Defaults to Sonnet 5.5 and Medium, kept in `localStorage`. Agent runs get the model as `TURINGOS_AGENT_MODEL` (passed to `claude --model`); chat answers use model and effort. Effort is not passed to agent runs. |
| Shell mode | If the AI is unreachable the composer switches to shell mode and what you type runs as a command through `/shell`. `$ cmd` runs a command at any time. See `trust/README.md`. |
| Voice | The mic button records on the machine and transcribes with local Whisper (the `ggml-base.en` model downloads on first use), or Wispr Flow if set up with `turingos voice`. |
| Corners | Bottom-left: agent state (Agent idle, Starting, Agentic) and the task. Bottom-right: sandbox, game mode, CPU, memory. Top-right under the menu bar: weather (Open-Meteo, located by IP), with a detail card on click. |
| Dock | Hidden until the cursor reaches the bottom edge. Terminal, Files, Browser, Bazaar, Settings, and Install TuringOS when the Calamares installer is present. Icons magnify toward the cursor on a mass-spring-damper. |
| Side panel | Ctrl/⌘+J, or click the clock or the Wi-Fi icon. Holds Notifications, Wi-Fi, Google Calendar and GitHub. |
| Wi-Fi | Scan and connect through NetworkManager (`nmcli`), from the side panel. |
| GitHub widget | Your open PRs and review requests through `gh` (run `gh auth login` first). Refreshed every 5 minutes. |
| Calendar widget | Google OAuth through the system browser, with PKCE and a loopback redirect. Shows the next event once connected, and a "Connect Google Calendar" empty state otherwise. Needs the keys in section 9. |
| Command palette | Ctrl/⌘+K or Super+Space. Opens commands (Bazaar, Terminal, Browser, Files, Install, theme, Settings) and a plugin list. The plugin list is a prototype over a built-in catalogue; installing there only flips in-memory state. |
| Bazaar window | Opens from the dock or the palette. Lists the registry's MCP servers from `turingosd`, installs and uninstalls them, and enables or disables them per project. Shows "[offline catalogue]" when it is serving the cache or the bundled registry. The skills and plugins tabs are still built-in sample entries. |
| Clawd | A pixel mascot that patrols the bottom-right corner. Click it, or shake the cursor, to ask a one-off question (Haiku, one question and one answer, no history). Ctrl/⌘+Enter sends. |
| Theme | Light and dark, following the system until the toggle is used; the choice is remembered. The switch is a circular reveal. |
| Sample data | If `~/.turingos` doesn't exist the page shows sample agent data and says so at the bottom. CPU, memory, battery and Wi-Fi stay real. |

Not built yet:

- Streaming agent steps into the page (a plan, live steps, a result card).
  The agent's output goes to `~/.turingos/logs/agent-session-*.log` and the
  page only sees running or not.
- The permission sheet. `ui/web/js/plan-renderer.js` draws a plan review
  (Edit, Reject, Approve) against the `/plan` socket, but `index.html` does not
  load it.
- Notifications with Undo. The Notifications list is seeded with sample
  entries, and the page adds one when an agent task finishes.
- Pull request views and an Actions menu.
- Running other `turingos` commands from the UI.
- Passing effort to agent runs.

---

## 1. Run it

See [SETUP.md](SETUP.md). Short version:

```bash
./turingos ui                  # app window
./ui/run.sh --gfx sw.lite      # the lighter look a VM without 3D gets
```

To work on CSS you can also open `ui/web/index.html` in a browser. It runs on
sample data without a backend.

Ground rules for working on it:

- Develop and test inside a VM (QEMU, UTM, VMware).
- `ui/run.sh` refuses to run as root.
- The page can only reach the system through `window.shell`
  (`ui/web/js/bridge.js`), and that only offers the calls in
  `protocol/v1/README.md`. Its Content-Security-Policy is `default-src 'self'`
  with `connect-src 'self'`, so the page makes no requests of its own.
  Weather, GitHub, Google and Anthropic calls are made by `turingosd`.

---

## 2. Surfaces and keys

| Key | Action |
|---|---|
| Ctrl/⌘+K | Open or close the command palette |
| Super+Space | Open the command palette; first stashes other windows on a side workspace (`session/turingos-omni`) |
| Ctrl/⌘+J | Open or close the side panel |
| ↑ / ↓, Enter, Esc | Move, select and close in the palette |
| Ctrl/⌘+Enter | Send, in Clawd's chat |
| Ctrl/⌘+W | Close the Bazaar window |
| Super+Esc | A plain terminal, whatever state the shell is in |

The shell is a browser window underneath. `bridge.js` blocks the browser's
own shortcuts (Ctrl+W, T, N, Q, R, zoom, F5, F11, F12, Alt+Left/Right), so
Ctrl/⌘+Q does not quit it.

---

## 3. Connecting the backend

The page never touches the system. It opens `/desktop` on the bridge, which
forwards to `turingosd`, and gets one snapshot whenever something changes
(`ui/web/js/bridge.js` defines `window.shell`; the messages are in
`protocol/v1/README.md`).

`daemon/src/state.rs` builds the snapshot:

| Snapshot field | Source |
|---|---|
| `live` | `~/.turingos` exists |
| `user.name` | The login user's first name |
| `agent.running` | `agent_pid` in `state.json` is a live process |
| `agent.task` | `agent_task` in `state.json` |
| `sandbox` | `active_sandbox` in `state.json` (folder name) |
| `gameMode` | `game_mode` is `on` in `state.json` |
| `system.cpu`, `system.mem`, `system.host` | `/proc/stat`, `/proc/meminfo`, hostname |
| `system.battery` | `/sys/class/power_supply/BAT*` |
| `system.wifi` | `nmcli` |
| `system.installer` | Whether the Calamares launcher is present |
| `weather` | Open-Meteo, every 15 minutes |
| `github` | `gh`, every 5 minutes |
| `calendar` | Google Calendar, every 5 minutes |

Starting an agent from the page runs `turingos agent start <project> <task>`
with `TURINGOS_AGENT_MODEL` set, detached, so a run outlives a restart of the
service.

`turingos sandbox merge`, `sandbox rollback` and `agent stop` still ask a
yes/no question on the terminal, so the page can't call them yet. They need a
non-interactive flag first. `bazaar install` and `bazaar uninstall` already
take `-y`.

---

## 4. GitHub

The widget uses GitHub's own CLI, `gh`:

| UI data | Command |
|---|---|
| My PRs | `gh pr list --author @me --json number,title,headRefName,additions,deletions,statusCheckRollup,reviewDecision,url` |
| Review requests | `gh search prs --review-requested=@me --state open --json number,title,repository,url` |

If `gh` is missing or logged out, the widget keeps its last reading.

---

## 5. Design system

The shell follows TuringOS design language v1.0. The reference is
`assets/design-language/DESIGN_LANGUAGE.md` with boards in
`assets/design-language/boards/`. The values the page uses are in
`ui/web/css/tokens.css`, which is the copy to edit. The Anthropic and Claude
palette is not used.

### Principles

1. Black is the room. Every surface is black or a tint of it; chrome stays grayscale.
2. Orange is the signal. One orange moment per view: the live thing (an agent working, the primary action, focus). Never decoration.
3. Nothing lands unreviewed. States follow the sandbox: plan, diff, approve, merge. Approval and destructive states carry a label, never colour alone.
4. Soft, light, local. Squircle corners, floating surfaces, glass that switches off without a GPU, fonts bundled.

### Palette

| Name | Hex | Token |
|---|---|---|
| Branding Orange | `#E85002` | `--tos-brand-orange` |
| Black (Primary) | `#000000` | `--tos-primary-bg` |
| Dark Gray | `#333333` | `--tos-dark-gray` |
| Gray | `#646464` | `--tos-gray` |
| Light Gray | `#A7A7A7` | `--tos-light-gray` |
| White | `#F9F9F9` | `--tos-white` |

The brand gradient runs at 135deg through `#000000` (0%), `#C10801` (35%),
`#F16001` (70%) and `#D9C3AB` (100%). Those stops are
`--tos-gradient-stop-1` to `--tos-gradient-stop-4`, and the gradient itself is
`--tos-brand-gradient`. Use it on heroes, boot and installer art, and active
borders: one per view, never behind body text. Two more gradients are
derived from it: `--tos-active-border-gradient` and `--tos-tile-gradient`
(app tiles in the Bazaar and the dock).

The palette has no green, blue or yellow, and none should be added. Every
other colour is a tint of these (alpha, or a mix with black or white). The
stop colours double as states: `#C10801` is the danger fill, `#F16001` the
orange hover, `#D9C3AB` (cream) means done or an added line.

### Roles

`tokens.css` defines these under `:root[data-theme="dark"]` and
`:root[data-theme="light"]`:

| Token | Dark | Light | Use |
|---|---|---|---|
| `--bg` | `#000000` | `#F9F9F9` | Page background |
| `--surface` | `#141414` | `#EFEFEF` | Cards, chips |
| `--surface-2` | `#242424` | `#E5E5E5` | Raised surfaces |
| `--surface-strong` | `#333333` | `#D4D4D4` | Strongest fill |
| `--line` | Gray at 28% | Dark Gray at 14% | Hairlines |
| `--text` | `#F9F9F9` | `#000000` | Primary text |
| `--muted` | `#A7A7A7` | `#333333` | Secondary text |
| `--faint` | `#646464` | `#646464` | Graphics and 24px+ text on dark; fine for text on light |
| `--accent` | `#E85002` | `#E85002` | Fills |
| `--accent-text` | `#E85002` | `#C10801` | Text and links |
| `--accent-hover` | `#F16001` | `#F16001` | Hover |
| `--on-accent` | `#000000` | `#000000` | Labels on orange |
| `--danger` | `#C10801` | `#C10801` | Fill only, with a white label |
| `--danger-text` | `#D76864` | `#C10801` | Error text |
| `--done` | `#D9C3AB` | `#6B5A48` | Done, added lines |
| `--glow` | orange at 25% | orange at 18% | Desktop glow |
| `--bar` | `#141414` at 75% | `#F9F9F9` at 75% | Menu bar fill |
| `--focus-ring`, `--focus-outline` | black gap, white ring | reversed | Focus |

Labels on orange fills are black (5.58:1). White on orange is 3.57:1, so only
at 24px and up. Red `#C10801` on black is 3.30:1, so it is never used for
text on dark. The full contrast table is in the design language file.

State colours: idle is a Light Gray dot; working is an orange dot with a soft
halo; needs approval is an orange outline chip with a lock; done and added
lines are cream with a check or `+`; failed and removed lines are a red fill
with a white label and an ✕ or `−`.

### Type

- Timeless Sans (`--sans`, weights 300 to 800) for the interface.
- Timeless Serif (`--serif`, weights 200 to 700) for moments of voice: the clock, the greeting, sheet titles.
- JetBrains Mono (`--mono`) for anything the machine said or you would copy: commands, paths, diffs, small caps labels. It is named first in the stack but is not bundled, so machines without it fall back to SF Mono or the system monospace font.

Both Timeless fonts are variable fonts in `ui/web/fonts/` (MIT), loaded with
`@font-face` in `tokens.css`, so they work offline.

| Name | Spec |
|---|---|
| Clock | Serif 300, 96px/1, clamped up to 164px, -0.03em |
| Display | Serif 400, 64/1.05, -0.02em |
| Heading | Serif 400, 46/1.1, -0.01em |
| Title | Serif 500, 22/1.3 |
| Lead | Sans 400, 17/1.5 |
| Body | Sans 400, 14/1.5 |
| UI | Sans 400, 13/18 |
| Label | Sans 500, 12/16 |
| Caption | Mono 500, 11/16, capitals, +0.08em |
| Code | Mono 400, 12/18 |

### Shape and space

Radii: `--r-xs` 4px (key caps), `--r-sm` 8px (buttons, fields), `--r-md` 12px
(cards, rows), `--r-lg` 16px (panels, popovers), `--r-xl` 22px (sheets, the
composer), `--r-pill` for chips, `--r-icon` 26% for app icons. Floating
surfaces (dock, sheets, composer, icons) use `corner-shape: squircle`.

Space is a 4px scale: `--s-1` 4, `--s-2` 8, `--s-3` 12, `--s-4` 16, `--s-5` 20,
`--s-6` 24, `--s-7` 32, `--s-8` 48, `--s-9` 64. The menu bar is
`--menubar-h`, 34px.

### Elevation and glass

Surfaces separate by tint, a hairline and `inset 0 0 0 0.5px` of white at
20%. Floating surfaces add `0 20px 48px` of black at 50% on dark (18% on
light). Frosted glass goes through `--glass-sm`, `--glass-md`, `--glass-lg` and
`--glass-xl` (20, 24, 28 and 40px blur). They are set to `none` when
`<html data-gfx>` is `lite` or `minimal`, which is how the page drops blur on
machines without a GPU (`boot.js`, `css/gfx.css`).

### Motion

- One easing, `--ease-out`: `cubic-bezier(0.23, 1, 0.32, 1)`.
- Durations: `--dur-exit` 150ms, `--dur-base` 160ms (hover, press), `--dur-enter` 220ms (pop-ins, menus), `--dur-slow` 360ms (the panel slide).
- The dock's magnification is the only thing driven by a spring (a mass-spring-damper). Everything else uses the easing above, not springs.
- Primary buttons press to `scale(.97)` with `--btn-press-overlay`, an 8% black inset.
- `prefers-reduced-motion` turns off every animation and transition (`base.css`).

### Icons

Feather-style line icons: 1.6px stroke, round caps and joins, 16px by
default, drawn in `currentColor`. `.icon` in `base.css` sets this. The glyphs
are inline `<symbol>`s in `ui/web/index.html`, and their licence is
`ui/web/assets/icons/feather/LICENSE`. To add one, add a `<symbol id="ic-name">`
with shape data only, no `width`, `height` or `stroke`. Brand logos for
plugins are in `ui/web/assets/icons/brands/`.

### Controls

Buttons are 36px high with an 8px radius and 13px/500 type.

| Kind | Look |
|---|---|
| Primary | Orange fill, black label. Hover `--accent-hover`. Pressed: `scale(.97)` plus the 8% black overlay. Disabled: Dark Gray fill, Gray label. |
| Secondary | Dark Gray fill, white label, hover `--btn-secondary-hover` (`#434343`). |
| Ghost | Transparent, hover `--btn-ghost-hover` (white at 8%), pressed `--btn-ghost-press` (12%). |
| Danger | `#C10801` fill, white label, hover `--btn-danger-hover` (`#C61B15`). |

Focus is a 2px gap in the ground colour and then a 2px ring in the text
colour (`--focus-ring`). On orange fills the ring is always white.

### Brand mark

The menu bar and the greeting still draw the Claude spark
(`#claude-spark` in `index.html`, from `ui/web/assets/brand/claude-symbol.svg`).
The design language calls for a vector TuringOS mark there instead; the spark
should stay only where it means Claude itself, such as Claude notifications.
`ui/web/assets/brand/app-icon.png` is the window and launcher icon.

---

## 6. Demo script (about 3 minutes)

1. Open on the desktop. The assistant is part of the system here, not an app.
2. Type `@`, pick a project, describe a task, press Enter. The bottom-left corner changes to Agentic and the bottom-right shows "Sandbox active". The original project is untouched.
3. Open a terminal from the dock and run `turingos agent status`, then `turingos sandbox diff`.
4. Merge or roll back with `turingos sandbox merge` or `turingos sandbox rollback`. Nothing reaches the project until a person says so.
5. Run `turingos game on` and show the corner. The agent drops to low priority and keeps running.
6. Open the Bazaar from the dock and install a tool.
7. Click the light/dark toggle to finish on the circular reveal.

---

## 7. Likely questions

- **What stops the AI from doing damage?** The agent works in a copy of the project. Nothing reaches the real project until a person merges it, and rollback discards it. The trust daemons add scoped, expiring grants and an audit log (`trust/README.md`).
- **What leaves the machine?** The prompt and whatever the agent reads in its sandbox go to the model provider. API keys stay in `~/.turingos/config.env` (mode 600).
- **Why an OS and not an app?** Sandboxes, process priorities and the permission layer need OS-level access that an app can't enforce.
- **What happens offline?** The shell and system status still work. Tasks that need Claude show an error, and the composer falls back to shell mode.
- **What is built and what is borrowed?** Debian is the base. The control layer, the sandbox flow, the trust daemons, the Bazaar and the shell are ours.

---

## 8. Files

| File | Purpose |
|---|---|
| `ui/run.sh` | Launcher for a checkout: bridge, shell helper, `turingosd` and the app window |
| `daemon/src/` | `turingosd`, one module per job: `state` (snapshots), `system`, `projects`, `agent`, `launch` (dock, links), `weather`, `github`, `google` (Calendar OAuth), `anthropic` (Clawd, chat), `voice`, `bazaar`, `gfx`, `control` (hotkey and status socket), `session` (the page's socket), `rpc` |
| `ui/web/js/bridge.js` | `window.shell`: the only way from the page to the system |
| `ui/web/index.html` | Markup, the icon sprite, and the script and style load order |
| `ui/web/css/` | Design tokens (`tokens.css`), then one stylesheet per feature |
| `ui/web/js/` | One classic script per feature, sharing one global scope |
| `ui/web/js/theme.js` | Picks the theme before first paint |
| `ui/web/boot.js` | Picks the graphics level before first paint |
| `ui/web/fonts/` | Timeless Sans and Serif (variable, bundled) |
| `ui/web/assets/brand/` | Claude symbol, app icon |
| `ui/web/assets/icons/` | Feather licence, plugin brand logos, other icon sets with their licences |
| `assets/design-language/` | Design language v1.0: the spec, tokens, boards |
| `ui-docs/SETUP.md` | Running it, troubleshooting |
| `ui-docs/UI_SHELL.md` | This document |
| `ui-docs/NEXT_FEATURES.md` | The plan the side panel, GitHub, Calendar and Clawd were built from |

## 9. Config keys (`~/.turingos/config.env`)

Calendar and Clawd need these. Use plain `KEY=VALUE` lines (`turingos`
shell-quotes what it writes). `turingosd` parses the file itself, because on
the ISO the desktop starts from the session, not from a shell that sourced it.
A real environment variable wins over the file.

| Key | Used by | Where to get it |
|---|---|---|
| `ANTHROPIC_API_KEY` | Clawd and composer answers | An Anthropic API key |
| `GOOGLE_CLIENT_ID` | Calendar widget | A Google Cloud OAuth "Desktop app" client (Cloud Console, APIs & Services, Credentials) |
| `GOOGLE_CLIENT_SECRET` | Calendar widget | The same OAuth client |

Without them, Clawd and the composer report that they need an API key, and
the Calendar widget shows its connect prompt. The Google refresh token is
stored in `~/.turingos/google-tokens.json`.
