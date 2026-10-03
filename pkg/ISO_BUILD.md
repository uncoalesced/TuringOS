# Building the TuringOS ISO

TuringOS ships as a Debian 13 ("trixie") live ISO built with `live-build`.
The ISO is the only install target: there is no separate .deb or Arch package.

---

## How it fits together

1. `debian-live/sync-scripts.sh` stages TuringOS into
   `debian-live/config/includes.chroot/` in its final layout (see
   [File layout](#file-layout)). live-build copies that tree into the image
   before any hook runs.
2. `debian-live/config/package-lists/turingos.list.chroot` lists every Debian
   package the image needs, including the desktop UI's runtime libraries.
3. The hooks in `debian-live/config/hooks/normal/` run in order:

| Hook | What it does |
|---|---|
| `0200-trim` | Purges office suites, printing, Bluetooth, unused GPU drivers |
| `0300-locale-trim` | Strips locales, man pages and docs (keeps `/usr/share/doc/turingos`) |
| `0400-install-turingos` | Checks the staged install, adds gum and the app-launcher entry |
| `0450-build-ui` | Builds the Tauri UI (`ui/src-tauri`) with Debian's Rust, installs `/usr/bin/turingos-ui`, removes the toolchain and source |
| `0470-autologin-kiosk` | lightdm autologin into openbox, ordered after live-config |
| `0500-install-claude-cli` | Installs Claude Code (native installer, npm fallback) and OpenCode; first-login API key prompt |
| `0900-boot-timeout` (binary) | Boot menus (isolinux and GRUB) start the live entry after 3 seconds |

On boot, lightdm logs `user` into openbox, and
`includes.chroot/etc/xdg/openbox/autostart` starts `turingos-ui` fullscreen.

---

## Build

On a Debian 13 machine:

```bash
sudo apt install live-build rsync git

git clone https://github.com/uncoalesced/turingos
cd turingos
./debian-live/sync-scripts.sh

cd debian-live
sudo lb config --distribution trixie --architectures amd64 \
    --archive-areas "main contrib non-free-firmware"
sudo lb build
```

Expect 20–40 minutes. The build needs internet: hook 0450 fetches Rust
crates (pinned by `ui/src-tauri/Cargo.lock`) and hook 0500 downloads Claude
Code and OpenCode. Without network, 0500 skips both and `turingos init`
offers to install Claude Code later; 0450 has no offline mode.

The ISO lands in `debian-live/` as `live-image-amd64.hybrid.iso`.
Clean rebuild: `sudo lb clean --purge && sudo lb build` (re-run
`sync-scripts.sh` first after any change to the repo).

Build from a checkout with LF line endings. `.gitattributes` forces LF, so a
fresh clone is fine even on Windows; scripts with CRLF endings break in the
image.

---

## Test in a VM

```bash
qemu-system-x86_64 -m 4G -enable-kvm -cdrom live-image-amd64.hybrid.iso -boot d
```

The UI should come up fullscreen. Open a terminal from the dock and check:

```bash
turingos version
turingos init
turingos help
```

Live login: `user` / `live` (live-config's default).

---

## First boot

1. lightdm autologins `user`; openbox starts `turingos-ui` in kiosk mode
2. The first interactive terminal shows the welcome banner
   (`/etc/profile.d/turingos-first-run.sh`) and asks for an Anthropic API key
   once (`/etc/profile.d/turingos-apikey.sh`)
3. `turingos init` checks dependencies and offers to pick a model provider

---

## File layout

```
/usr/bin/turingos             → ../lib/turingos/turingos
/usr/bin/turingos-ui          desktop UI (built by hook 0450)
/usr/lib/turingos/
├── turingos                  entrypoint
├── core/      config.sh ui.sh logging.sh init.sh
├── agent/     claude.sh model.sh nim.sh
├── sandbox/   btrfs.sh diff.sh
├── bazaar/    registry.sh install.sh registry.json
├── game/      gamemode.sh
├── monitor/   system.sh
├── voice/     voice.sh wispr_transcribe.py
└── pkg/       turingos-install-claude-cli.sh
/usr/share/doc/turingos/      copyright, WORKFLOW.md
/etc/profile.d/               turingos-first-run.sh, turingos-apikey.sh
/usr/local/bin/               claude, opencode
```

`tests/install_parity.sh` (run in CI) checks that every module `turingos`
sources is staged by `sync-scripts.sh`.

User data (sandboxes, logs, config, keys) lives in `~/.turingos/`.
