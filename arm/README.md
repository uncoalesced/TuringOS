# ARM64 build & test

TuringOS builds for **amd64 and arm64**. The debian-live config is shared,
so an arm64 image has every feature the x86 one has: the Tauri desktop UI,
kiosk autologin, Claude Code + OpenCode, the Bazaar MCP registry, Game Mode,
and the Kali-style **Live system (persistence)** boot entry.

What actually differs per architecture:

| | amd64 | arm64 |
|---|---|---|
| Build command | `cd debian-live && sudo lb config --architectures amd64 … && sudo lb build` | `./arm/build.sh` |
| Output | `debian-live/live-image-amd64.hybrid.iso` | `debian-live/live-image-arm64.hybrid.iso` |
| Boot menus | isolinux (BIOS) + GRUB (UEFI) | GRUB (UEFI) only |
| x86-only X drivers (`vesa`, `vmware`) | installed | skipped via `#if ARCHITECTURES` in the package list |
| VM test | `qemu-system-x86_64` | `./arm/test-qemu.sh` |

## Build

```bash
./arm/build.sh
```

The script stages the repo (`sync-scripts.sh`), runs `lb config
--architectures arm64`, then `lb build` — and purges any previous build config
so an amd64 chroot can never leak into an arm64 image.

**Host requirements:** an arm64 Debian Trixie machine. The build hooks execute
real binaries in the chroot (`apt-get`, a full `cargo build` of the UI in
hook 0450, `claude --version` in 0500), so live-build's `--architectures`
flag alone is not enough. On an x86 host you need user-mode emulation:

```bash
sudo apt install qemu-user-static binfmt-support
```

Expect the UI compile to be much slower under emulation (whisper.cpp via
`whisper-rs` is the heavy part). Everything else — hooks, package lists,
boot menus — behaves exactly as on amd64.

## Test in a VM

```bash
./arm/test-qemu.sh                          # finds debian-live/live-image-arm64*.iso
./arm/test-qemu.sh -- -m 8G                 # extra qemu args after --
QEMU_DISPLAY=vnc=:1 ./arm/test-qemu.sh      # headless host: VNC on :5901
DISK=/tmp/arm.qcow2 ./arm/test-qemu.sh      # + 20G virtio disk for the Calamares install
```

Needs `qemu-system-aarch64` and the EDK2 firmware
(`sudo apt install qemu-system-arm qemu-efi-aarch64`). On an arm64 host it
uses KVM automatically; elsewhere it falls back to TCG emulation (slow but
works). The script gives the `virt` machine a virtio-gpu (a KMS device for
Xorg; without it the UI drew in software on a bare EFI framebuffer) and a USB
tablet + keyboard (absolute pointer, no lag). Under TCG everything is still
slow: judge rendering on KVM. The UI should come up fullscreen — same smoke
test as amd64:

```bash
turingos version && turingos init
```

## Test persistence (any architecture)

```bash
# 1. make a persistence disk (also works on a USB: /dev/sdX)
sudo ./pkg/make-persistence.sh -y /tmp/turingos-persistence.img 4G

# 2. boot the ISO with it attached
./arm/test-qemu.sh -- -drive if=virtio,format=raw,file=/tmp/turingos-persistence.img

# 3. at the boot menu choose "Live system (persistence)", then:
touch ~/saved-on-persistence   # log out/in or reboot the VM

# 4. boot the persistence entry again — the file must still be there
ls ~/saved-on-persistence
```

## Caveats

- Not built in CI yet: GitHub's arm64 runners (`ubuntu-24.04-arm`) run the
  shell and Rust test suites for arm64, but the ISO build itself still runs
  on a Debian machine (see `pkg/ISO_BUILD.md`).
- The Charm apt repo (`gum`), Claude Code's native installer and OpenCode all
  ship arm64 binaries — hook 0400/0500 need no arch handling.
- Report arm64 boot problems in `debian-live/KNOWN_ISSUES.md` with the device
  or VM machine type you used.
