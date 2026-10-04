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
| `0420-install-brave` | Brave from its signed apt repo as the default browser (`xdg-open`, `x-www-browser`, `$BROWSER`), Claude extension installed and pinned by policy |
| `0450-build-ui` | Builds the Tauri UI (`ui/src-tauri`) with Debian's Rust, installs `/usr/bin/turingos-ui`, removes the toolchain and source |
| `0470-autologin-kiosk` | lightdm autologin into openbox, ordered after live-config |
| `0490-install-homebrew` | Homebrew in `/home/linuxbrew/.linuxbrew`, owned by the live user, on `PATH` |
| `0495-installer` | Calamares installer (TuringOS branding, `turingos-install` launcher, autologin + Homebrew handed to the new account) |
| `0500-install-claude-cli` | Installs Claude Code (native installer, npm fallback) and OpenCode; first-login API key prompt |
| `0900-boot-timeout` (binary) | Boot menus (isolinux and GRUB) start the live entry after 3 seconds |
| `0910-persistence-menu` (binary) | Clones the live entry into a Kali-style *Live system (persistence)* entry (isolinux and GRUB) |

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
crates (pinned by `ui/src-tauri/Cargo.lock`), hooks 0420/0490 fetch Brave and
Homebrew (no offline mode either) and hook 0500 downloads Claude
Code and OpenCode. Without network, 0500 skips both and `turingos init`
offers to install Claude Code later; 0450 has no offline mode.

The ISO lands in `debian-live/` as `live-image-amd64.hybrid.iso`.
Clean rebuild: `sudo lb clean --purge && sudo lb build` (re-run
`sync-scripts.sh` first after any change to the repo).

Build from a checkout with LF line endings. `.gitattributes` forces LF, so a
fresh clone is fine even on Windows; scripts with CRLF endings break in the
image.

---

## Build for arm64

```bash
./arm/build.sh
```

Same shared config, `--architectures arm64`; the output is
`live-image-arm64.hybrid.iso`. Two arch-specific pieces are handled for you:

- `turingos.list.chroot` wraps `xserver-xorg-video-vesa` and
  `xserver-xorg-video-vmware` in `#if ARCHITECTURES amd64 i386` (trixie ships
  them for x86 only), and hook `0900` skips isolinux (arm64 images are
  EFI/GRUB-only).
- The build host must run arm64 binaries — an arm64 Debian machine, or an
  x86 host with `qemu-user-static` + `binfmt-support`. The hooks execute
  `apt-get`, `cargo build` and `claude --version` inside the chroot.

Switching architectures in one checkout **requires** `sudo lb clean --purge`
first (otherwise live-build reuses the other arch's chroot);
`arm/build.sh` detects this and does it for you. Details: [`../arm/README.md`](../arm/README.md).

---

## Test in a VM

```bash
qemu-system-x86_64 -m 4G -enable-kvm -cdrom live-image-amd64.hybrid.iso -boot d
```

For the arm64 ISO use `../arm/test-qemu.sh` (qemu-system-aarch64 + EDK2
firmware; no `-enable-kvm` unless the host is arm64).

The UI should come up fullscreen. Open a terminal from the dock and check:

```bash
turingos version
turingos init
turingos help
```

Live login: `user` / `live` (live-config's default).

---

## Persistence

The boot menus offer a **Live system (persistence)** entry — hook `0910`
clones the live entry with `persistence` on the kernel command line, Kali
style. Prepare the persistence media once, from any Linux machine:

```bash
sudo ../pkg/make-persistence.sh /dev/sdX        # a USB stick (partition added in free space)
sudo ../pkg/make-persistence.sh /tmp/p.img 4G    # a disk image, for QEMU
```

Either way you get an ext4 partition labelled `persistence` containing
`persistence.conf` with `/ union`. Boot and pick the persistence entry:
everything you change under `/` — `~/.turingos`, API keys, installed MCP
tools — is written back to that partition and survives reboots. The plain
entry stays ephemeral. The image already ships `cryptsetup`/`lvm2`, so
LUKS-encrypted persistence media is recognised too (`persistence-encryption=luks`
on the kernel command line).

QEMU check: attach the image with `-drive if=virtio,format=raw,file=/tmp/p.img`
(alongside the `-cdrom` line above), choose the persistence entry, create a
file in `$HOME`, reboot and confirm it is still there.

---

## First boot

1. lightdm autologins `user`; openbox starts `turingos-ui` in kiosk mode
2. The first interactive terminal shows the welcome banner
   (`/etc/profile.d/turingos-first-run.sh`) and asks for an Anthropic API key
   once (`/etc/profile.d/turingos-setup-apikey.sh`)
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
/etc/profile.d/               turingos-first-run.sh, turingos-setup-apikey.sh
/usr/local/bin/               claude, opencode
```

`tests/install_parity.sh` (run in CI) checks that every module `turingos`
sources is staged by `sync-scripts.sh`.

User data (sandboxes, logs, config, keys) lives in `~/.turingos/`.
