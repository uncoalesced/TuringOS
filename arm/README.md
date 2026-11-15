# ARM64 build and test

TuringOS builds for amd64 and arm64. The debian-live config is shared, so an
arm64 image has what the x86 one has: the desktop UI, kiosk autologin,
Claude Code and OpenCode, the Bazaar MCP registry, Game Mode, the Calamares
installer, and the persistence and safe mode boot entries.

What differs per architecture:

| | amd64 | arm64 |
|---|---|---|
| Build command | `./debian-live/build-amd64.sh` | `./arm/build.sh` |
| Output | `debian-live/turingos-amd64.hybrid.iso` | `debian-live/turingos-arm64.hybrid.iso` |
| Aliases | `live-image-amd64.hybrid.iso`, `turningos-amd64.hybrid.iso` | `live-image-arm64.hybrid.iso`, `turningos-arm64.hybrid.iso` |
| Boot menus | isolinux (BIOS) and GRUB (UEFI) | GRUB (UEFI) only |
| x86-only X drivers (`vesa`, `vmware`) | installed | skipped via `#if ARCHITECTURES` in the package list |
| VM test | `qemu-system-x86_64` | `./arm/test-qemu.sh` |

## Build

```bash
./arm/build.sh
```

The script stages the repo (`sync-scripts.sh`), runs `lb config
--architectures arm64 --linux-flavours arm64`, then `sudo lb build`. If the
previous build in the checkout was for another architecture, it runs
`lb clean --purge` first, so an amd64 chroot can't leak into an arm64 image.

Host requirements: an arm64 Debian trixie machine. The build hooks run real
binaries in the chroot (`apt-get`, a full `cargo build` of `turingosd` in hook
0450, `claude --version` in 0500), so live-build's `--architectures` flag
alone is not enough. On an x86 host you need user-mode emulation:

```bash
sudo apt install qemu-user-static binfmt-support
```

Expect the daemon compile to be much slower under emulation (whisper.cpp via
`whisper-rs` is the heavy part). Everything else (hooks, package lists, boot
menus) behaves as on amd64.

GitHub's native arm64 runner can do the build for you: the manual `ISO`
workflow (`.github/workflows/iso.yml`) runs `arm/build.sh` on
`ubuntu-24.04-arm` in a `debian:trixie` container and uploads the ISO with a
`.sha256` file. See `pkg/ISO_BUILD.md`.

## Test in a VM

```bash
./arm/test-qemu.sh                          # finds debian-live/live-image-arm64*.iso
./arm/test-qemu.sh path/to/image.iso        # a specific ISO
./arm/test-qemu.sh -- -m 8G                 # extra qemu args after --
QEMU_DISPLAY=vnc=:1 ./arm/test-qemu.sh      # headless host: VNC on :5901
DISK=/tmp/arm.qcow2 ./arm/test-qemu.sh      # plus a 20G virtio disk for the Calamares install
```

Needs `qemu-system-aarch64` and the EDK2 firmware
(`sudo apt install qemu-system-arm qemu-efi-aarch64`). On a host with
`/dev/kvm` it uses KVM; elsewhere it falls back to TCG emulation (slow but
works). The script gives the `virt` machine 4 GB of RAM, 2 CPUs, a virtio-gpu
(a KMS device for the session; without it the UI draws in software on a bare
EFI framebuffer) and a USB tablet and keyboard (absolute pointer, no lag).
Under TCG everything is slow, so judge rendering on KVM. The UI should come up
fullscreen. Same smoke test as amd64:

```bash
turingos version && turingos init
```

## Test persistence (any architecture)

Every live entry is built with `persistence` on its kernel command line, so
you only need the media:

```bash
# 1. make a persistence disk (also works on a USB: /dev/sdX)
sudo ./pkg/make-persistence.sh -y /tmp/turingos-persistence.img 4G

# 2. boot the ISO with it attached
./arm/test-qemu.sh -- -drive if=virtio,format=raw,file=/tmp/turingos-persistence.img

# 3. in the VM:
touch ~/saved-on-persistence   # then reboot the VM

# 4. boot again with the same disk attached: the file must still be there
ls ~/saved-on-persistence
```

Without a partition labelled `persistence` attached, nothing is saved.

## Caveats

- CI runs the shell and Rust test suites on arm64 (`ubuntu-24.04-arm`), but
  the ISO build itself is not part of the regular CI gate. Build it with
  `./arm/build.sh` or the manual `ISO` workflow.
- Hooks 0400 (gum from the Charm apt repo) and 0500 (Claude Code, OpenCode)
  have no per-architecture code; they rely on those sources serving arm64.
- Report arm64 boot problems in `debian-live/KNOWN_ISSUES.md` with the device
  or VM machine type you used.
