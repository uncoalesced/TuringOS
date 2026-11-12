<!-- Engineered by uncoalesced -->
# TuringOS design language (v1.0, 27 Oct 2026)

Offline copy of the design canvas. Agents: read this file and `tokens.css`; you do not need the online artifact.
Palette source of truth: `assets/pallete/renewed_palette.jpg`. Do not use the Anthropic/Claude palette anywhere.

- Visual boards: `boards/*.html` (open in a browser, works offline) and `png/*.png` (quick look).
- Tokens: `tokens.css` (ready to port into `ui/web/css/tokens.css`; not yet applied to the repo).
- Editable canvas source: `source/` (`.dc.html` files plus `canvas.json`, for the online Design editor only).
- Logo: `assets/logo/turing-os-no-bg-logopng.png` (transparent) and `turing-os-logo.png` (on off-white).

## Principles
1. **Black is the room.** Primary black holds every surface; chrome stays grayscale.
2. **Orange is the signal.** One orange moment per view: the live thing (agent working, primary action, focus). Never decoration.
3. **Nothing lands unreviewed.** States follow the sandbox: plan, diff, approve, merge. Approval and destructive moments are labelled, never colour alone.
4. **Soft, light, local.** Squircle corners, floating surfaces, glass that turns off without a GPU, fonts bundled.

## Palette
| Name | Hex | Token | Role |
|---|---|---|---|
| Branding Orange | `#E85002` | `--tos-brand-orange` | Signal, primary action, focus |
| Primary | `#000000` | `--tos-primary-bg` | Every ground |
| Dark Gray | `#333333` | `--tos-dark-gray` | Panels, raised surfaces |
| Gray | `#646464` | `--tos-gray` | Hairlines, dividers, icon fills |
| Light Gray | `#A7A7A7` | `--tos-light-gray` | Secondary text, captions |
| White | `#F9F9F9` | `--tos-white` | Primary text, light ground |

Gradient (135deg): `#000000` 0%, `#C10801` 35%, `#F16001` 70%, `#D9C3AB` 100%. Heroes, boot, installer slides, active borders. One per view, never behind body text. Strips use `to right`.
The source image prints the orange as RGB 232, 80, 20; the hex is canonical (232, 80, 2).

## Roles (tints only)
| Role | Dark | Light | Token |
|---|---|---|---|
| Background | `#000000` | `#F9F9F9` | `--bg` |
| Surface | `#141414` (Dark Gray 40%) | `#EFEFEF` (Black 4%) | `--surface` |
| Surface raised | `#242424` (70%) | `#E5E5E5` (Black 8%) | `--surface-2` |
| Surface strong | `#333333` | `#D4D4D4` (Light Gray 45%) | `--surface-strong` |
| Line | Gray at 28% | Dark Gray at 14% | `--line` |
| Text | `#F9F9F9` | `#000000` | `--text` |
| Text muted | `#A7A7A7` | `#333333` | `--muted` |
| Text faint | `#646464` (graphics, 24px+) | `#646464` (5.62:1, ok for text) | `--faint` |
| Accent | `#E85002`, hover `#F16001` | fill `#E85002`, text `#C10801` | `--accent` |

## State colours (the palette has no green, blue or yellow; do not add them)
- **Idle**: Light Gray dot. **Working**: Orange dot with soft halo, the one live thing. **Needs approval**: Orange outline chip with a lock. **Done / merged / added line**: Cream `#D9C3AB` with a check or `+`. **Failed / destructive / removed line**: Red `#C10801` fill with a White label and an ✕ or `−`. Red alone is 3.30:1 on Black, so it never carries text.

## Contrast (WCAG 2.x from the hex values)
| Pair | Ratio | Use |
|---|---|---|
| White on Black | 19.95 | text |
| Light Gray on Black | 8.73 | muted text |
| Cream on Black | 12.34 | text |
| Orange on Black | 5.58 | text, icons |
| **Black on Orange** | 5.58 | **button labels** |
| White on Orange | 3.57 | 24px and up only |
| White on Red `#C10801` | 6.04 | danger fill |
| Red on Black | 3.30 | graphics only |
| Gray on Black | 3.55 | graphics, 24px+ |
| Light Gray on Dark Gray | 5.25 | muted on panels |
| Gray on Dark Gray | 2.14 | never for text |
| Dark Gray on White | 12.00 | light-ground muted |
| Gray on White | 5.62 | light-ground faint |
| Red on White | 6.04 | light-ground accent text |
| Light Gray on White | 2.29 | decoration only |

## Type
Fonts: Timeless Sans (300–800) and Timeless Serif (200–700) in `ui/web/fonts` (MIT); JetBrains Mono optional.
| Name | Spec | Use |
|---|---|---|
| Clock | Serif 300, 96/1, clamp to 164, -0.03em | Desktop clock |
| Display | Serif 400, 64/1.05, -0.02em | Hero |
| Heading | Serif 400, 46/1.1, -0.01em | Greeting, prompts |
| Title | Serif 500, 22/1.3 | Sheet titles |
| Lead | Sans 400, 17/1.5 | Intro text |
| Body | Sans 400, 14/1.5 | Reading |
| UI | Sans 400, 13/18 | Default control text |
| Label | Sans 500, 12/16 | Chips, small controls |
| Caption | Mono 500, 11/16, caps +0.08em | Status corners, section labels |
| Code | Mono 400, 12/18 | Commands, paths, diffs |
Serif = moments of voice; Sans = all UI; Mono = anything the machine said or you'd copy.

## Shape and space
Radii: 4 `--r-xs` key caps; 8 `--r-sm` buttons, fields; 12 `--r-md` cards, rows; 16 `--r-lg` panels, popovers; 22 `--r-xl` sheets, composer; pill chips; 26% app icons. `corner-shape: squircle` on floating surfaces only (dock, sheets, composer, icons).
Space (4px base): 4, 8, 12, 16, 20, 24, 32, 48, 64 as `--s-1` to `--s-9`. Menu bar 34px.

## Elevation, glass, motion
Separate surfaces with tint plus a hairline plus `inset 0 0 0 0.5px rgb(249 249 249 / .2)`; floating: `0 20px 48px rgb(0 0 0 / .5)` on dark, `/ .18` on light. Glass `--glass-sm/md/lg/xl` (20/24/28/40px blur); `none` in lite and minimal graphics levels. Desktop glow: `radial-gradient(150% 110% at 50% 125%, var(--glow), transparent 72%)`.
Easing `cubic-bezier(0.23, 1, 0.32, 1)`. Durations: exit 150, base 160 (hover, press), enter 220 (pop-in, menus), slow 360 (panel slide). The dock uses a mass-spring-damper, nothing else does. `prefers-reduced-motion`: no animation, no transition.
Icons: stroke 1.6, round caps and joins, 16px default, `currentColor` (Feather style).

## Controls
Buttons 36px high, radius 8, 13/500. Primary: Orange fill, Black label; hover `#F16001`; pressed `scale(.97)` plus 8% black overlay; disabled Dark Gray fill with Gray label. Secondary: Dark Gray fill, White label, hover `#434343`. Ghost: transparent, hover White at 8%. Danger: `#C10801` fill, White label, hover `#C61B15`. Focus ring: 2px Black gap then 2px White on dark (reversed on light); on orange fills always the White ring.

## Boards
01 Overview · 02 Palette · 03 Roles and contrast · 04 Type · 05 Shape and space · 06 Elevation, motion, icons · 07 Controls · 08 Surfaces (menu bar, permission sheet, task and diff, widgets, dock, notification) · 09 Desktop dark · 10 Desktop light.

## Open items
- Apply `tokens.css` to `ui/web/css/tokens.css` and remove the legacy Claude aliases there (`--japonica`, `--pampas`, `--cloudy`, `--tuatara`, `--tuatara-deep`, `--error: #bf4d43`).
- `ui/web/assets/brand/claude-symbol.svg` is still the Claude spark; replace with the TuringOS mark.
- Boot splash, GRUB and Calamares slides are not designed yet.
