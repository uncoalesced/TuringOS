# Building the TuringOS ISO

TuringOS ships as a Debian 13 ("trixie") live ISO built with `live-build`,
for amd64 and arm64. The ISO is the only install target: there is no separate
.deb or Arch package.

---

## How it fits together

1. `debian-live/sync-scripts.sh` stages TuringOS into
   `debian-live/config/includes.chroot/` in its final layout (see
   [File layout](#file-layout)). live-build copies that tree into the image
   before any hook runs.
2. `debian-live/config/package-lists/turingos.list.chroot` lists the Debian
   packages the image needs, including the desktop service's runtime
   libraries.
3. The hooks in `debian-live/config/hooks/normal/` run in order:

| Hook | What it does |
|---|---|
| `0200-trim` | Purges office suites, printing, Bluetooth, unused GPU drivers |
| `0300-locale-trim` | Strips locales, man pages and docs (keeps `/usr/share/doc/turingos`) |
| `0350-hyprland` | Installs Hyprland, `hyprland-guiutils`, XWayland and the Hyprland portal from `trixie-backports` (Hyprland is not in the frozen trixie archive) |
| `0400-install-turingos` | Checks the staged install, adds gum and the app-launcher entry |
| `0420-install-brave` | Brave from its signed apt repo as the default browser (`xdg-open`, `x-www-browser`, `$BROWSER`), Claude extension installed and pinned by policy |
| `0450-build-daemon` | Builds the desktop service (`daemon/`) with Debian's `rustc-web`/`cargo-web`, installs `/usr/bin/turingosd`, removes the toolchain and source |
| `0460-plymouth-theme` | Makes the TuringOS splash the default plymouth theme |
| `0470-autologin-kiosk` | lightdm autologin of `user` into the `turingos-hyprland` session, ordered after live-config; checks that the openbox fallback session file exists |
| `0475-fallback` | Patches openbox's `rc.xml`: Super+Esc terminal, Super+Space command bar, and the rule that makes the shell window the desktop |
| `0480-install-trust-model` | The trust daemons, the bridge (`turingos-bridged-ws`, which serves the UI), the `turingos-audit`, `turingos-cap` and `turingos-sandbox` commands, and their system units |
| `0490-install-homebrew` | Homebrew in `/home/linuxbrew/.linuxbrew`, owned by the live user, on `PATH` |
| `0495-installer` | Calamares installer (TuringOS branding, `turingos-install` launcher, autologin and Homebrew handed to the new account) |
| `0500-install-claude-cli` | Installs Claude Code (native installer, npm fallback) and OpenCode (pinned version); first-login API key prompt |
| `0900-boot-timeout` (binary) | Boot menus (isolinux and GRUB) start the default entry after 3 seconds |
| `0910-persistence-menu` (binary) | Clones the live entry into a persistence entry and a safe mode entry (`turingos.safe`), in isolinux and GRUB |
| `0920-boot-brand` (binary) | TuringOS boot art and colours for isolinux and GRUB; renames the entries from "Live system" to "TuringOS" |

On boot, lightdm logs `user` into the `turingos-hyprland` session
(`session/turingos-hyprland`). It starts Hyprland with
`/etc/turingos/hyprland.conf`, and its autostart starts `turingosd` and opens
the UI that `turingos-bridged-ws` serves in a Brave app window
(`session/turingos-kiosk`), restarted by `turingos-respawn` if it crashes. If
the machine has no render node (`/dev/dri/renderD*`) or Hyprland exits with an
error, the session falls back to X with openbox on the same VT, which runs the
same shell window.

---

## Build

On a Debian 13 machine:

```bash
sudo apt install live-build rsync git

git clone https://github.com/uncoalesced/TuringOS
cd TuringOS
./debian-live/build-amd64.sh
```

`build-amd64.sh` stages the repo (`sync-scripts.sh`), runs `lb config` for
trixie and amd64 with the `main contrib non-free-firmware` archive areas and
`boot=live components quiet splash persistence` as the boot options, and runs
`sudo lb build`. It purges the previous build first if that was for another
architecture.

The build needs internet: hook 0350 uses `trixie-backports`, hook 0450 fetches
Rust crates (pinned by `daemon/Cargo.lock`), hooks 0420 and 0490 fetch Brave
and Homebrew (no offline mode), and hook 0500 downloads Claude Code and
OpenCode. Without network, 0500 skips both and `turingos init` offers to
install Claude Code later.

The ISO lands in `debian-live/` as `turingos-amd64.hybrid.iso`. The script
also links `live-image-amd64.hybrid.iso` and `turningos-amd64.hybrid.iso` to
it. Clean rebuild: `sudo lb clean --purge` in `debian-live/`, then
`./debian-live/build-amd64.sh` (it re-stages first).

Build from a checkout with LF line endings. `.gitattributes` forces LF, so a
fresh clone is fine even on Windows; scripts with CRLF endings break in the
image.

---

## Build for arm64

```bash
./arm/build.sh
```

Same shared config, `--architectures arm64`; the output is
`debian-live/turingos-arm64.hybrid.iso` (with the same two aliases). Two
arch-specific pieces are handled for you:

- `turingos.list.chroot` wraps `xserver-xorg-video-vesa` and
  `xserver-xorg-video-vmware` in `#if ARCHITECTURES amd64 i386` (trixie ships
  them for x86 only), and hook `0900` skips isolinux (arm64 images are
  EFI/GRUB-only).
- The build host must run arm64 binaries: an arm64 Debian machine, or an x86
  host with `qemu-user-static` and `binfmt-support`. The hooks run `apt-get`,
  `cargo build` and `claude --version` inside the chroot.

Switching architectures in one checkout needs `sudo lb clean --purge` first
(otherwise live-build reuses the other arch's chroot). Both build scripts
detect this and do it for you. Details: [`../arm/README.md`](../arm/README.md).

---

## Build in GitHub Actions

`.github/workflows/iso.yml` (named "ISO") builds both images on GitHub's
runners. It only runs when you start it (`workflow_dispatch`): an ISO build
takes about an hour, so it is not part of the regular CI gate.

Start it from the Actions tab (workflow "ISO", Run workflow), or with
`gh workflow run iso.yml`.

It runs two jobs, side by side, and one failing does not cancel the other:

| Job | Runner | Build script |
|---|---|---|
| `iso (amd64)` | `ubuntu-latest` | `debian-live/build-amd64.sh` |
| `iso (arm64)` | `ubuntu-24.04-arm` | `arm/build.sh` |

The arm64 job runs on a native arm64 runner, so it does not depend on
`qemu-user`. Each job:

1. Checks out the repo and frees disk space on the runner (removes .NET, the Android SDK, GHC and the CodeQL tools).
2. Runs the build script inside a privileged `debian:trixie` container with the repo mounted at `/work`. The container installs `live-build`, `sudo`, `rsync`, `git`, `xorriso`, `squashfs-tools`, `debootstrap`, the GRUB and syslinux packages and a few others first.
3. Writes `turingos-<arch>.sha256` next to the ISO, from `sha256sum turingos-<arch>.hybrid.iso`.
4. Uploads the ISO and the checksum file as one artifact, `turingos-amd64-iso` or `turingos-arm64-iso`. The artifact is stored uncompressed and kept for 14 days.

The job timeout is 240 minutes. Download the result from the run page, or with
`gh run download <run-id>`.

---

## Test in a VM

```bash
qemu-system-x86_64 -m 4G -enable-kvm -cdrom debian-live/turingos-amd64.hybrid.iso -boot d
```

For the arm64 ISO use `../arm/test-qemu.sh` (qemu-system-aarch64 plus EDK2
firmware; KVM only if the host is arm64).

The UI should come up fullscreen. Open a terminal from the dock (or press
Super+Esc) and check:

```bash
turingos version
turingos init
turingos help
```

Live login: `user` / `live` (live-config's default).

---

## Persistence

Both build scripts put `persistence` on the kernel command line of every live
entry, and hook `0910` adds a separate persistence entry and a safe mode
entry. live-boot only keeps changes if it finds a partition labelled
`persistence` (with `persistence.conf`); without one, an entry behaves like
any other live boot and nothing is saved.

Prepare the persistence media once, from any Linux machine:

```bash
sudo ../pkg/make-persistence.sh /dev/sdX        # a USB stick (partition added in free space)
sudo ../pkg/make-persistence.sh /tmp/p.img 4G    # a disk image, for QEMU
```

Either way you get an ext4 partition labelled `persistence` containing
`persistence.conf` with `/ union`. Boot with it attached: everything you change
under `/` (`~/.turingos`, API keys, installed MCP tools) is written back to
that partition and survives reboots. The image ships `cryptsetup` and `lvm2`,
so LUKS-encrypted persistence media is recognised too
(`persistence-encryption=luks` on the kernel command line).

QEMU check: attach the image with `-drive if=virtio,format=raw,file=/tmp/p.img`
next to the `-cdrom` line above, boot, create a file in `$HOME`, reboot and
confirm it is still there.

---

## First boot

1. lightdm autologins `user` and the session opens the UI in a Brave app window
2. The first interactive terminal shows the welcome banner
   (`/etc/profile.d/turingos-first-run.sh`) and asks for an Anthropic API key
   once (`/etc/profile.d/turingos-setup-apikey.sh`)
3. `turingos init` checks dependencies and offers to pick a model provider

---

## File layout

```
/usr/bin/turingos             → ../lib/turingos/turingos
/usr/bin/turingosd            desktop service behind the bridge (built by hook 0450)
/usr/lib/turingos/
├── turingos                  entrypoint
├── core/      config.sh ui.sh logging.sh init.sh
├── agent/     claude.sh model.sh nim.sh
├── sandbox/   btrfs.sh diff.sh
├── bazaar/    registry.sh install.sh registry.json
├── game/      gamemode.sh
├── monitor/   system.sh
├── voice/     voice.sh wispr_transcribe.py
├── pkg/       turingos-install-claude-cli.sh
├── session/   turingos-kiosk turingos-gfx-detect turingos-omni
│              turingos-hyprland turingos-hyprland-autostart
├── daemons/   the trust daemons and turingos-bridged-ws (hook 0480)
└── ui/web/    the page the bridge serves
/etc/turingos/                turingos.toml, policy.toml, hyprland.conf, tools.d/,
                              trust/bazaar.pub (the Bazaar's Ed25519 public key)
/usr/share/doc/turingos/      copyright, WORKFLOW.md, protocol-v1.md
/etc/profile.d/               turingos-first-run.sh, turingos-setup-apikey.sh
/usr/local/bin/               claude, opencode
```

`tests/install_parity.sh` (run in CI) checks that every module `turingos`
sources is staged by `sync-scripts.sh`.

User data (sandboxes, logs, config, keys) lives in `~/.turingos/`.
