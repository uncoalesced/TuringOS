# ui-shell

The assistant layer for our Claude-powered Linux OS (CachyOS base, KDE). It is the part people see: a menu bar, a Raycast-style command bar, a permission sheet, notifications with Undo, and a side panel of widgets.


## Status

| Built | Not built yet |
|---|---|
| Electron app in `ui/`, launched with `./claudeos ui` | Command bar, PR views, Actions menu (Ctrl/⌘+K focuses the composer for now) |
| Menu bar: Claude spark + brand, agent status (pulsing dot when working), Wi-Fi, battery, light/dark toggle, clock | Task view, permission sheet |
| Desktop, vertically centred: clock, greeting with the user's first name, "What do you want to cook?" composer | Notifications with Undo, widgets side panel |
| @ (or +) project picker listing git repos; Enter runs `claudeos agent start <project> <task>` | |
| Weather in the top-right corner (Open-Meteo, geolocated by IP), click for the full card | |
| Bottom corners: agent status and task, sandbox / game mode / CPU / memory | |
| Live state from `~/.claudeos/state.json`, sample data fallback | Running other `claudeos` commands from the UI |
| Light/dark in Claude brand colours, circular reveal | Spring engine, progressive blur |
| macOS-style app icon (`assets/brand/app-icon.png`, squircle) | |

The spec below describes the full target. Where it differs from what's built, the **Status** table wins.

---

## 1. Run it

See [SETUP.md](SETUP.md). Short version:

```bash
./claudeos ui              # app window
KIOSK=1 ./claudeos ui      # fullscreen, use this for the demo
LITE=1 ./claudeos ui       # software drawing, for VMs without 3D (auto-detected)
```

To preview on a Mac without the OS, run the same command, or open `ui/index.html` in Chrome.

### Safety rules (hard rules for this project)

- The OS only ever runs inside a VM (QEMU/UTM). Never on real hardware, and never on a work laptop's own boot disk.
- Scripts never use `sudo` and refuse to run as root.
- The UI reads `~/.claudeos` and never writes system files itself.
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

The page never touches the system. `ui/main.js` is the only part that does, and it hands the page one snapshot at a time over a bridge (`ui/preload.js`).

### What's wired today

`main.js` reads these and pushes a snapshot every 2 s and whenever `~/.claudeos` changes:

| Snapshot field | Source |
|---|---|
| `live` | `~/.claudeos` exists (ClaudeOS initialised) |
| `agent.running` | `agent_pid` in `state.json` is a live process |
| `agent.task` | `agent_task` in `state.json` |
| `sandbox` | `active_sandbox` in `state.json` (folder name) |
| `gameMode` | `game_mode == "on"` in `state.json` |
| `system.cpu`, `system.mem`, `system.host` | Node `os` module |
| `system.battery` | `/sys/class/power_supply/BAT*` (Linux) |
| `system.wifi` | `nmcli` (Linux, NetworkManager) |

### Next: live agent steps

`claudeos agent start` runs Claude with `--output-format stream-json` and writes it to `~/.claudeos/logs/agent-*.log`. `main.js` will tail the newest log and translate lines into the events below.

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

- Anything that changes the system must go through `approval` first. In ClaudeOS that means the agent works in a sandbox, and **Merge** / **Rollback** are the approval.
- Read-only actions (reading settings, listing packages, `git status`) don't need approval.
- `commands[]` must be the exact commands that will run, not a description of them.
- **Needed from the backend team:** `sandbox merge`, `sandbox rollback` and `agent stop` currently ask a yes/no question in the terminal. The UI has no terminal, so these need a non-interactive flag (e.g. `--yes`) before the UI can call them.

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

Claude's brand colours, used as tokens in `ui/styles.css`.

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

`#262624`, `#6F6C64` and `#8A877E` aren't brand colours; they exist for contrast (Cloudy on Pampas is too faint for body text).

Light/dark follows the system. The half-circle icon in the menu bar overrides it with a circular reveal, and the choice is remembered.

### Typography

- **Timeless Sans** (`--sans`, weights 300–800) for the UI and **Timeless Serif** (`--serif`, 200–700) for the greeting and "Your day". Both are variable fonts bundled in `ui/fonts/`, so they work offline in the VM.
- `--mono` (system mono) for eyebrow labels, commands and code.
- Big numbers (clock, stats) use light weights (250–300) with tight letter spacing.
- Eyebrow labels use the mono font, uppercase, with wide letter spacing.

### Icons

Hand-drawn inline SVG, 16×16, 1.6px stroke, round caps. Keep new icons in the same style (Lucide and Phosphor match it).

**Brand:** official Claude assets live in `ui/assets/brand/`. The Claude spark is the menu bar mark and, spinning slowly, the "agent working" indicator. `app-icon.png` is the window and launcher icon. Don't use GitHub's logo.

### Motion

- **No opacity animations.** Things appear and disappear with blur, scale and position.
- **Springs for interactive motion** (`snappy`, `smooth`, `bouncy`) so interruptions keep velocity. The current build uses a custom ease-out curve for entrances; the spring engine is not built yet.
- **Only animate `transform`, `filter` and `backdrop-filter`.** The theme reveal uses `clip-path` as the one exception.
- **Stagger:** list items enter 45 ms apart.
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
- **What did you build versus what already existed?** CachyOS and KDE are the base. We built the ClaudeOS control layer, the sandbox flow, and the ui-shell UI.

---

## 8. Files

| File | Purpose |
|---|---|
| `ui/run.sh` | Launcher: installs Electron on first run, detects VM quirks, opens the app |
| `ui/main.js` | Reads `~/.claudeos`, system stats and weather; pushes snapshots to the page |
| `ui/preload.js` | The only bridge between the page and the system |
| `ui/index.html` | Markup |
| `ui/styles.css` | Design tokens and styles |
| `ui/app.js` | Renders snapshots, clock, theme toggle, sample data |
| `ui/theme.js` | Picks the theme before first paint |
| `ui/fonts/` | Timeless Sans and Serif (variable, bundled) |
| `ui/assets/brand/` | Claude symbol, logo, app icon |
| `ui-docs/SETUP.md` | Running it in the VM, troubleshooting |
| `ui-docs/UI_SHELL.md` | This document |
