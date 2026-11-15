# Changelog

All notable changes to TuringOS are listed here, newest first. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Release names are not Semantic Versions: `1.3-beta` and `1.3-stable` are labels for tagged builds.

Each section covers the commits between one tag and the previous one. The Bazaar's web catalogue lives in a separate repository, `turingos-bazaar`, and has its own history. The 1.3-stable rebrand of that site is not listed here.

## [1.3-stable] - 2026-11-15

Design language v1.0 across the desktop, boot menus, splash and installer. The Bazaar and the local bridge now fail closed. A manual ISO build workflow. The manual, `DOCUMENTATION.md`, is new.

### Added

- Design language v1.0 in `assets/design-language/`: `DESIGN_LANGUAGE.md`, `tokens.css`, ten boards in HTML and PNG, the editable canvas source, and a transparent logo (`assets/logo/turing-os-no-bg-logopng.png`).
- Boot art from `debian-live/branding/make-boot-art.py`: isolinux and GRUB splashes, plymouth images, a 256 px installer logo and three Calamares slides. New binary hook `0920-boot-brand` applies them, recolours the isolinux and GRUB menus, and renames "Live system" entries to "TuringOS".
- Plymouth boot splash. New hook `0460-plymouth-theme` sets the `turingos` theme and rebuilds the initrd. The `plymouth` and `plymouth-label` packages are in the image. The hook fails the build if the script or label plugin is missing, because without the label plugin the disk passphrase prompt draws nothing.
- Calamares installer branding in palette colours, with real slides.
- README banner, rendered from the design language to `assets/banner/turingos-banner.png`.
- Manual ISO build workflow, `.github/workflows/iso.yml`. It builds amd64 and arm64 on native runners (`ubuntu-latest` and `ubuntu-24.04-arm`) in a `debian:trixie` container, so arm64 no longer depends on `qemu-user`. It writes a `.sha256` file per image and uploads both as artifacts kept for 14 days.
- Tests: `tests/boot_brand.sh` (hook 0920 on amd64 and arm64 trees, and the committed art), `tests/kiosk_display.sh` (screen-size probing and ozone choice with stubbed `hyprctl` and `xdpyinfo`), and `trust/tests/test_local_auth.py` (local-access hardening).
- Palette guard in `tests/benchmark.sh`. It fails if the old Claude palette names or hex values reappear under `ui/web`, `debian-live/config` or `session`.
- `release_notes_v1.3-beta.md` and a `benchmark_report.json` from the beta qualification run, committed after the beta tag.
- `DOCUMENTATION.md`, this changelog, and release notes for 1.3-stable.

### Changed

- The web UI uses the design language tokens in `ui/web/css/tokens.css` (roles, radii, spacing, motion, button states, focus ring). The legacy Claude palette aliases (`japonica`, `pampas`, `cloudy`, `tuatara`) are gone and every use was rewritten.
- Plan sheet: approve is the one orange fill, "needs approval" is an orange outline chip with a lock, reject is a secondary button. The lock is an icon drawn with a CSS mask, since the image has no font with that glyph. Error text uses a lighter red that passes contrast.
- Window controls are grayscale; red appears only when hovering the close button.
- Version string bumped to 1.3 in the CLI (`turingos version` prints `TuringOS v1.3`) and in the installer branding.
- CI: the bridge and auth tests now run under a 300 second abort with a stack dump, so a hung test fails fast instead of using the six hour job limit. `test_local_auth.py` is part of that step.
- The release benchmark skips the daemon `cargo check` when the ALSA development libraries are absent. The CI daemon job still builds and tests `turingosd` in the ISO's Debian container.

### Fixed

- Black screen at login under Hyprland. The shell probed the screen size with an `xdpyinfo` that waited forever on an XWayland that never started (seen in a VMware VM). The probe now asks `hyprctl` under Wayland, every probe has a 3 second timeout, and Brave uses the Wayland ozone platform when `WAYLAND_DISPLAY` is set. The Hyprland shell rule and the Super+Space hotkey now also match the app id Brave uses on Wayland (`brave-127.0.0.1__-Default`), because it ignores `--class` there.
- `shell-helper` could hang once its 64 KB output cap was reached, on Python 3.14: the process was never reaped. It now drains the pipe first, with a 5 second bound.
- Plymouth label plugin missing from the image, which made the disk passphrase prompt invisible (see Added).

### Security

- Bazaar index signature fails closed. The CLI and `turingosd` now reject a remote index when the signature, the public key or `openssl` is missing, instead of trusting it. Unverified remote data is no longer cached. Negative tests were added.
- Bazaar installer hardening against registry-driven injection: tool keys and `env_required` names are validated before use, the registered npm package argument is pinned to the verified version, npm and archive entries must carry a SHA-256 (fail closed), and archives with absolute or parent-escaping member paths are refused.
- Local access hardening:
  - `bridged`: the egress allowlist is decided on the server only; `http` and `https` only; no redirects; no hosts that resolve to non-public addresses; a cap on response size.
  - `bridged-ws`: the connecting process must belong to a logged-in user (checked through the kernel's socket table); helper sockets must be owned by the uid in their file name; `/shell` no longer matches the desktop socket; replies are read to the newline instead of one chunk.
  - `shell-helper`: refuses peers it cannot identify.
  - `agentd-plan`: adds `reject_plan`; approve and execute work only from the right state; a plan runs once.

## [1.3-beta] - 2026-10-19

The release that moved the desktop off Tauri onto the local bridge, added the trust daemons, the Bazaar's remote catalogue and an Ed25519 signature check, and a Hyprland session. This section covers everything between the `v1.2` and `v1.3-beta` tags, which includes work from 5 to 18 October.

### Added

- Trust model: JSON schemas for grants, audit entries, plans, UI fragments and tool manifests; daemons `auditd` (hash-chained log), `capd` (expiring grants), `sandboxd` (bubblewrap), `toolreg`, `agentd-llm`, `agentd-plan`, `memoryd`, `bridged` (egress) and `bridged-ws` (WebSocket server); their systemd units; command-line tools for audit, grants and sandbox runs; reference tools and manifests; an end-to-end test suite; and a plan review sheet in the UI.
- Fallback ("Phase 3"): when the model is unreachable the composer switches to shell mode (`/shell`, run in your login session by `turingos-shell-helper`); `turingos-respawn` restarts the shell window and opens a terminal after repeated crashes; the "(safe mode)" boot entry (`turingos.safe`); Super+Esc opens a terminal.
- `turingosd`, a Rust desktop service, replaces the Tauri app. It serves the page's state, projects, agent start, dock, voice and Google sign-in.
- The page runs on the bridge (`turingos-bridged-ws`) in a Brave app window (`session/turingos-kiosk`), with a `/desktop` WebSocket to `turingosd` and Origin and Host checks on every WebSocket. Protocol documented in `protocol/v1/`.
- Real-browser contract test for the shell window (`tests/kiosk_contract.sh`), run weekly in CI.
- Hyprland session with an X and Openbox fallback (`session/turingos-hyprland`), Hyprland autostart and configuration with the new window rules and gradient borders.
- Wi-Fi scan and connect through NetworkManager.
- Bazaar: remote catalogue fetch with a 24 hour cache and SHA-256 verification of npm packages; a daemon module and UI integration; `bazaar rules` and `bazaar toggle` for per-project enable and disable; Thunar context actions; Ed25519 index signature verification with a bundled public key (`trust/keys/bazaar.pub`, installed to `/etc/turingos/trust/bazaar.pub`); robust `file://` handling for offline and local signature checks.
- Persistent live boot: `--bootappend-live "boot=live components quiet splash persistence"` in both build scripts; the Calamares post-install hook resolves the real UID 1000 account and hands it LightDM autologin and Homebrew ownership; boot menu cloning avoids repeating parameters.
- Release benchmark, `tests/benchmark.sh`, with a JSON report (`benchmark_report.json`).
- Renewed palette: gradient window borders in Hyprland (`rgb(e85002) rgb(f16001)`), dark gray for inactive windows, and matching tokens in `ui/web/css/tokens.css`. The approved logo.
- Codacy scan hardening (pinned tools, a per-tool timeout, binaries excluded).

### Changed

- The desktop UI is a web page, not a Tauri app. Frosted glass goes through `--glass` tokens. The evening greeting starts at 17:00.
- The bridge serves the UI from `/usr/lib/turingos/ui/web` and at `/`, and runs `/shell` in the login session rather than as the `turingos` system user.
- The `0200` trim hook cleans up the filesystem more thoroughly.
- Release notes for the beta described the signature check as minisign. The code has always used `openssl pkeyutl -verify` with a raw Ed25519 key.

### Fixed

- `--linux-flavours` is passed explicitly for arm64 and amd64 builds, so a leftover flavour from a previous build is not reused.
- The `turingosd` build needed the `axum` `query` and `tokio` `process` features.
- arm64 UEFI bootloader detection in Calamares; an explicit `PATH` in the Calamares bootloader job (it was missing `start-stop-daemon`); root access to XWayland for the installer through `xhost`; the installer icon path.
- The trust hook installs `file-reader.py` and `launch-shell.sh` from where they are staged, and the trust source is staged so hook 0480 can install it.
- Kiosk contract test in CI containers (browser sandbox, bad-flags infobar).
- `glib` 0.18.5 patched for RUSTSEC-2024-0429 (vendored, since no fixed version was reachable).

### Security

- Bazaar index signatures are verified when a public key, `openssl` and a `.sig` are all available. In this release a missing key, a missing `openssl` or a missing signature file did not stop the index from being used; 1.3-stable closes that gap.
- Every WebSocket route on the bridge only opens for the page the bridge itself served (Origin and Host checks).
- npm package checksums are verified when the catalogue entry pins a version and SHA-256; in this release an unpinned entry was still installed. 1.3-stable makes the pin mandatory.

## [1.2] - 2026-10-04

Brave as the default browser, an installer, and arm64.

### Added

- Brave as the default browser (`xdg-open`, `x-www-browser`, `$BROWSER`), with the Claude extension installed and pinned by policy, so `claude` login, the Anthropic Console and Google sign-in have somewhere to open.
- Calamares installer for a persistent install. GRUB ships on the image as `.deb` files, so installing works offline.
- arm64 support: `arm/build.sh`, `arm/test-qemu.sh` and an arm64 build of the same package list.
- Clawd, the pixel mascot, returned with a longer shake gesture to open it. Dock Settings opens `lxqt-config`.
- Codacy security scan workflow.

### Changed

- The README has a direct download link for the ISO.
- Codacy action updated; binary assets excluded from the scan.

### Fixed

- Homebrew is on `PATH` in the desktop session, and Brave's toolbar is trimmed down to the Claude extension.
- The Brave hook used a dead key URL and a missing package; hook 0420 now keeps the apt lists for hook 0450.
- The arm64 QEMU test script sets up a display.
- The GRUB packages are carried as `.deb` files instead of an ISO package pool.
- `sync-scripts.sh` line continuation (found by ShellCheck).
- arm64 build writes its architecture stamp with `sudo`.

## [1.1-stable] - 2026-10-03

This is the first tagged release. The history before it is not summarised here. The items below are the commits from its last days.

### Added

- First-login API key prompt, shown after the welcome banner and repeated if setup failed.
- Boot menus start the live entry after 3 seconds (hook `0900-boot-timeout`).
- Sonnet 5.5 (`claude-sonnet-5-5`) in the model picker, as the default, with an effort setting.
- `debian-live/KNOWN_ISSUES.md`, recording what was found booting the ISO in VMware.
- `en_US.UTF-8` generated into the image, because the live session had no locale and GTK fell back to C.

### Fixed

- Status HUD rows pad by characters rather than bytes, so the right border lines up, and the usage bar is 14 wide so a five digit MB value fits.
- The theme switch froze the page on a blank snapshot under WebKitGTK; the DMA-BUF renderer is always disabled there (blurred page, no text on VMware's `vmwgfx`).
- Whisper no longer transcribes silent recordings.
- `bazaar install` registered MCP servers incorrectly when the first argument was `-y`, because `jq` read it as its own option; arguments now reach `jq` through stdin.
- `gum` is used only on a terminal with a size, with a plain hidden prompt as the fallback (gum panicked on a 0-column terminal and the key was lost).
- Downloads of the charm key and the Claude Code installer are retried during the ISO build.
