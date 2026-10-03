# ui-shell

**TuringOS** is the on-screen name. The codebase is still called TuringOS/ui-shell, and the CLI, data dir, branch and package name haven't changed. This is the assistant layer for our Claude-powered Linux OS (Debian base, Openbox kiosk session), and it's the part people see: a menu bar, a Raycast-style command bar, a permission sheet, notifications with Undo, and a side panel of widgets.


## Status

| Built | Not built yet |
|---|---|
| Tauri app in `ui/` (page + Rust backend in `ui/src-tauri`), launched with `./turingos ui`, or `/usr/bin/turingos-ui` on the ISO | Command bar, PR views, Actions menu (Ctrl/⌘+K opens the command palette prototype) |
| Menu bar: Claude spark + "TuringOS" brand, Wi-Fi, battery, light/dark toggle, clock (click to open the side panel) | Task view, permission sheet |
| Desktop, vertically centred: clock, greeting with the user's first name, "What do you want to cook?" composer | Notifications with Undo |
| @ (or +) project picker listing git repos; Enter runs `turingos agent start <project> <task>` | |
| Weather in the top-right corner (Open-Meteo, geolocated by IP), click for the full card | |
| Bottom-left corner: agent status (**idle** / **working** / **agentic**) and task; bottom-right: sandbox / game mode / CPU / memory | |
| Live state from `~/.turingos/state.json`, sample data fallback | Running other `turingos` commands from the UI |
| Light/dark in Claude brand colours, circular reveal | Spring engine, progressive blur |
| macOS-style app icon (`assets/brand/app-icon.png`, squircle) | |
| "Focused today", centred above the composer (placeholder; no focus-tracking backend yet) | |
| Dock: hidden until the cursor hits the bottom edge. Floating (detached, all corners rounded, iOS-style continuous curvature via CSS `corner-shape: squircle`), tight resting spacing, macOS-style magnification toward the cursor with a name-label tooltip above the hovered icon. The magnification runs on a real spring (mass-spring-damper), not a CSS transition retargeting a JS value. Fixed set: Terminal, Files (wide fallback chain: xdg-open/dolphin/nautilus/pcmanfm/nemo/thunar), Browser, Settings, all launching real system commands via the Rust backend | Auto-discovered/configurable icon list |
| Model picker in the composer (Fable 5.1 / Opus 5.5 / Sonnet 5.5 / Haiku 4.5, Effort submenu Low–Max), defaults to Sonnet 5.5 / Medium, persisted locally. The model is passed to Claude agents as `TURINGOS_AGENT_MODEL` (`claude --model`); chat answers use model and effort | Effort isn't passed to agent runs |
| A composer message with no @project attached is a plain question, answered inline with one Claude call (the chosen model/effort). No sandbox, no agent. Attaching a project is what turns it into a real Claude Code task. That's the actual Claude-chat vs. Claude-Code distinction; there's no separate mode |
| Mic button next to send: records on the machine and transcribes with local Whisper (model downloads on first use), or Wispr Flow via `turingos voice` (unofficial, falls back to Whisper) | Not yet verified with a real microphone on the ISO |
| Clawd: patrols near the dock (slides only, no flip). Shake the cursor anywhere to open its chat (a real shake, meaning several quick reversals, not just fast motion). Ctrl/Cmd+Enter to send |
| Side panel (Ctrl/⌘+J or click the clock): a right-edge slide-in shell | Calendar/"Your day"/Ask widgets beyond what's listed below |
| GitHub widget in the side panel: My PRs + Review Requests via `gh` (assumes `gh auth login` already done), refreshed every 5 min, verified against a real authenticated account | |
| Calendar widget in the side panel: real Google OAuth (system-browser consent + loopback redirect, with `state` and PKCE). Shows the next event once connected, and an honest "Connect Google Calendar" empty state otherwise, not fake data | Needs a real Google Cloud OAuth "Desktop app" client (see §9 below) |
| Clawd: a small pixel mascot that patrols a corner near the dock and answers one-off questions (Haiku, single question → single answer, no history) in a popover | |

The spec below describes the full target. Where it differs from what's built, the Status table wins.

---

## 1. Run it

See [SETUP.md](SETUP.md). Short version:

```bash
./turingos ui              # app window
KIOSK=1 ./turingos ui      # fullscreen, use this for the demo
LITE=1 ./turingos ui       # software drawing, for VMs without 3D (auto-detected)
```

To preview on a Mac without the OS, run the same command or open `ui/web/index.html` in Chrome.

### Safety rules (hard rules for this project)

- The OS only ever runs inside a VM (QEMU/UTM). Never on real hardware, and never on a work laptop's own boot disk.
- Scripts never use `sudo` and refuse to run as root.
- The UI reads `~/.turingos` and never writes system files itself.
- The page is loaded from local files only; no network access from the UI.
- Never write to `/dev/*` or run `dd`, `mkfs` or `diskutil` against anything outside the project's `build/` folder.

---

## 2. What's in it (target)

| Surface | How to open | What it does |
|---|---|---|
| Menu bar | Always visible | Brand, assistant status, Wi-Fi, battery, search, light/dark toggle, date and time |
| Command bar | **Ctrl/⌘+K**, search icon, or the status item | Raycast-style list of commands; anything typed that isn't a command runs as a task |
| Pull requests | Command bar → My Pull Requests / Review Requests | List on the left, details and a streamed Claude summary on the right |
| Actions menu | **Tab** in a PR list | Check Out Branch, Review with Claude, Open in Browser, Copy Branch Name |
| Task view | Enter on a task | Plan, live steps, and a result card with a real control |
| Permission sheet | Appears when a task needs approval | Plain-language summary, the exact commands behind "Show commands", Deny / Allow |
| Notifications | Side panel | Every action the assistant takes, each with Undo |
| Widgets | Side panel (**Ctrl/⌘+J** or click the clock) | Calendar, battery, "Your day", year progress, GitHub, Ask |

### Keyboard

| Keys | Action |
|---|---|
| Ctrl/⌘+Q | Quit (built) |
| Ctrl/⌘+K | Open or close the command bar |
| Ctrl/⌘+J | Open or close the side panel |
| ↑ / ↓ | Move through a list |
| Enter | Run the selected item (in PR lists: check out the branch) |
| Ctrl/⌘+Enter | Review the selected PR with Claude |
| Tab | Open the Actions menu |
| Backspace (empty input) | Back from a PR list to the root list |
| Esc | Close the top-most thing: Actions → PR list → command bar → side panel. On the permission sheet, Esc means Deny. |

---

## 3. Connecting the backend

The page never touches the system. The Rust backend (`ui/src-tauri`) is the only part that does, and it hands the page one snapshot at a time over a bridge (`ui/web/js/bridge.js`, which defines `window.shell`).

### What's wired today

`src-tauri/src/state.rs` reads these and pushes a snapshot every second:

| Snapshot field | Source |
|---|---|
| `live` | `~/.turingos` exists (TuringOS initialised) |
| `agent.running` | `agent_pid` in `state.json` is a live process |
| `agent.task` | `agent_task` in `state.json` |
| `sandbox` | `active_sandbox` in `state.json` (folder name) |
| `gameMode` | `game_mode == "on"` in `state.json` |
| `system.cpu`, `system.mem`, `system.host` | `/proc/stat`, `/proc/meminfo`, hostname |
| `system.battery` | `/sys/class/power_supply/BAT*` (Linux) |
| `system.wifi` | `nmcli` (Linux, NetworkManager) |

### Next: live agent steps

`turingos agent start` runs Claude with `--output-format stream-json` and writes the output to `~/.turingos/logs/agent-*.log`. The backend will tail the newest log and translate its lines into the events below.

### Event protocol (target)

#### Backend → UI

| Event | Fields | Effect |
|---|---|---|
| `status` | `state`: `idle` \| `thinking` \| `working` \| `approval` \| `done` \| `error` | Menu bar status and the pulse dot |
| `plan` | `text` | One line of intent above the steps |
| `step` | `id`, `label`, `status`: `running` \| `waiting` \| `done` \| `skipped` \| `error`, `meta?` | Adds a step, or updates it if `id` exists |
| `approval` | `id`, `title`, `summary`, `commands[]` | Shows the permission sheet; the UI replies with a decision |
| `result` | `kind`: `diff` (`files`, `add`, `del`, `tests`) or `review` (`verdict`, `comments[]`) | Result card under the steps |
| `timeline` | `id`, `label` | Notification with Undo |
| `error` | `message` | Error step and error status |

#### UI → backend

| Message | Fields | When |
|---|---|---|
| `prompt` | `text` | The user runs a task from the command bar |
| `approval_response` | `id`, `decision`: `allow` \| `deny` | The user answers the permission sheet |
| `undo` | `id` | The user presses Undo on a notification |

### Rules for the backend

- Anything that changes the system must go through `approval` first. In TuringOS that means the agent works in a sandbox, and **Merge** / **Rollback** are the approval.
- Read-only actions (reading settings, listing packages, `git status`) don't need approval.
- `commands[]` must be the exact commands that will run, not a description of them.
- Needed from the backend team: `sandbox merge`, `sandbox rollback` and `agent stop` currently ask a yes/no question in the terminal. The UI has no terminal, so these need a non-interactive flag (e.g. `--yes`) before the UI can call them.

---

## 4. GitHub integration (target)

The backend uses GitHub's official CLI, `gh`. Run `gh auth login` once on the machine.

| UI data | Source |
|---|---|
| My Pull Requests | `gh pr list --author @me --json number,title,headRefName,additions,deletions,statusCheckRollup,reviewDecision,url` |
| Review Requests | `gh search prs --review-requested=@me --state open --json number,title,repository,url` |
| Summary and Risk | `gh pr diff <n>`, sent to Claude with a prompt for a 2–3 sentence summary and a one-line risk note |
| Review with Claude | Diff + CI results → Claude → suggested comments |
| Post review | `gh pr review <n> --comment --body-file review.md`, only after `approval` |
| Check Out Branch | `gh pr checkout <n>` |
| Where was I? | `git status`, `git log -5`, shell history, and TODOs in changed files, summarised by Claude |

---

## 5. Design system

### Color

Claude's brand colours, used as tokens in `ui/web/css/tokens.css`.

| Brand colour | Hex |
|---|---|
| Japonica | `#D97757` |
| Pampas | `#F4F3EE` |
| Cloudy | `#B1ADA1` |
| Tuatara | `#373734` |
| White | `#FFFFFF` |

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | Pampas | `#262624` (deeper Tuatara) | Page background |
| `--surface` | White | Tuatara | Cards, chips |
| `--text` | Tuatara | Pampas | Primary text |
| `--muted` | `#6F6C64` | Cloudy | Secondary text |
| `--faint` | Cloudy | `#8A877E` | Hints, idle dot |
| `--accent` | Japonica | Japonica | Pulse dot, brand mark, active states |
| `--danger` | `#BF4D43` | `#E07A70` | Errors |

`#262624`, `#6F6C64` and `#8A877E` aren't brand colours. They're there for contrast (Cloudy on Pampas is too faint for body text).

Light/dark follows the system. The half-circle icon in the menu bar overrides it with a circular reveal, and the choice is remembered.

### Typography

- Timeless Sans (`--sans`, weights 300–800) for the UI and Timeless Serif (`--serif`, 200–700) for the greeting and "Your day". Both are variable fonts bundled in `ui/web/fonts/`, so they work offline in the VM.
- `--mono` (system mono) for eyebrow labels, commands and code.
- Big numbers (clock, stats) use light weights (250–300) with tight letter spacing.
- Eyebrow labels use the mono font, uppercase, with wide letter spacing.

### Icons

[Feather](https://feathericons.com) (MIT), 24×24, 2px stroke, round caps. Only the glyphs in use ship (inline, in the sprite); `ui/web/assets/icons/feather/LICENSE` covers them. To add one, add it to the sprite in `ui/web/index.html` as `<symbol id="ic-name">`, with shape data only (no `width`/`height`/`stroke`; those come from `.icon`/`.wx`). Weather glyphs (`wx-*`) are Feather paths too. The "partly cloudy" symbols combine a small sun or moon (scaled down, shifted top-left) with Feather's cloud so they read at both 26px (menu bar) and 52px (weather card). If Feather doesn't have an icon for something, Lucide and Phosphor match its style.

Brand: official Claude assets live in `ui/web/assets/brand/`. The Claude spark is the menu bar mark. `app-icon.png` is the window and launcher icon (squircle; `ui/src-tauri/icons/` holds the copies Tauri builds with). Don't use GitHub's logo.

### Motion

- **No opacity animations.** Things appear and disappear with blur, scale and position.
- **Springs for interactive motion** (`snappy`, `smooth`, `bouncy`) so interruptions keep their velocity. The current build uses a custom ease-out curve for entrances; the spring engine isn't built yet.
- **Only animate `transform`, `filter` and `backdrop-filter`.** The theme reveal's `clip-path` is the one exception.
- Stagger: list items enter 45 ms apart.
- Buttons scale to 0.96 on press.
- `prefers-reduced-motion` turns every animation into an instant change.

---

## 6. Demo script (about 3 minutes)

1. **Open on the desktop.** "This is an OS where the assistant is part of the system, not an app."
2. **Start a task.** Ctrl+K → "Refactor the auth module and run the tests". The sandbox note appears in the bottom-right corner; the original project is protected.
3. **Watch it work.** Steps tick through live from the agent's output.
4. **Review changes.** The sheet shows files changed, lines added/removed, test results.
5. **Merge or roll back.** "Nothing is permanent until a human says so."
6. **Game mode.** Toggle it; the agent drops to background priority and keeps running.
7. **Light/dark.** Click the toggle to end on the circular reveal.

Backup: record the full run once as a video before presenting.

---

## 7. Likely judge questions

- **What stops the AI from doing damage?** The agent works in a copy-on-write sandbox. Nothing reaches the real project until a human merges it, and rollback discards it.
- **What leaves the machine?** Only the prompt and the context needed for the task. API keys stay local.
- **Why an OS and not an app?** Sandboxes, process priorities and a permission layer need OS-level access that an app can't enforce.
- **What happens offline?** The shell and system status still work; tasks that need Claude show an error instead of hanging.
- **What did you build versus what already existed?** Debian is the base. We built the TuringOS control layer, the sandbox flow, and the ui-shell UI.

---

## 8. Files

| File | Purpose |
|---|---|
| `ui/run.sh` | Launcher for a checkout: builds and opens the app |
| `ui/src-tauri/src/` | Rust backend, one module per job: `state` (snapshots), `system`, `projects`, `agent`, `launch` (dock, links), `weather`, `github`, `google` (Calendar OAuth), `anthropic` (Clawd, chat), `voice` |
| `ui/web/js/bridge.js` | `window.shell`: the only bridge between the page and the system |
| `ui/web/index.html` | Markup, the icon sprite (`<symbol>`s), and the script/style load order |
| `ui/web/css/` | Design tokens (`tokens.css`), then one stylesheet per feature |
| `ui/web/js/` | One classic script per feature (weather, widgets, composer, model picker, voice, dock, Clawd, palette, Bazaar...), sharing one global scope |
| `ui/web/js/theme.js` | Picks the theme before first paint |
| `ui/web/fonts/` | Timeless Sans and Serif (variable, bundled) |
| `ui/web/assets/brand/` | Claude symbol, logo, app icon |
| `ui/web/assets/icons/feather/LICENSE` | License for the inline Feather glyphs |
| `ui-docs/SETUP.md` | Running it in the VM, troubleshooting |
| `ui-docs/UI_SHELL.md` | This document |
| `ui-docs/NEXT_FEATURES.md` | The plan these features were built from, kept as a record of what was decided and why |

## 9. Config keys (`~/.turingos/config.env`)

The side panel's Calendar widget and Clawd need these. Use plain `KEY=VALUE`
lines (`turingos` shell-quotes what it writes). The backend parses this file
itself, because on the ISO the UI starts from the openbox session, not from a
shell that sourced it. A real environment variable still wins.

| Key | Used by | Where to get it |
|---|---|---|
| `ANTHROPIC_API_KEY` | Clawd's chat popover | An Anthropic API key |
| `GOOGLE_CLIENT_ID` | Calendar widget | A Google Cloud OAuth **"Desktop app"** client (Google Cloud Console → APIs & Services → Credentials) |
| `GOOGLE_CLIENT_SECRET` | Calendar widget | Same OAuth client as above |

Without these keys, Clawd shows a "needs an API key" error when you ask it
something, and the Calendar widget shows an honest "Connect Google Calendar"
empty state instead of a fake meeting. Both fail visibly, not silently.
