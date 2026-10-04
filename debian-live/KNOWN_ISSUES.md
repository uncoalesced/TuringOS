# Known issues

Status from booting the ISO in VMware Workstation 26 (BIOS and UEFI, 3D on and
off), October 2026. Login for debugging: `user` / `live` (live-config's
default), with passwordless sudo.

## Fixed and verified

- **Kiosk autologin.** lightdm now starts after live-config
  (`0470-autologin-kiosk`), so the boot goes straight to openbox and
  `turingos-ui` with no greeter.
- **Boot menu waited for a key.** `0900-boot-timeout` starts the live entry
  after 3 seconds.
- **Blank or blurred UI on VMware.** WebKitGTK's DMA-BUF renderer is disabled
  by the app; VMs without a render node fall back to software drawing.

- **No browser.** `claude` /login, the Anthropic Console, Google sign-in and
  UI links had nothing to open in. Brave is now the default for `xdg-open`,
  `x-www-browser` and `$BROWSER`, with the Claude extension force-installed
  by policy (`0480-install-brave`).
- **No persistent install.** Everything lived in RAM. Calamares now
  installs to disk (`0495-installer`). GRUB ships in the image, so it works
  offline.

## Open

- **`glib` 0.18 Dependabot alert.** Tauri's GTK 0.18 stack pins it; nothing to
  upgrade to until Tauri moves to gtk-rs 0.20+. TuringOS's own code doesn't
  call the affected API (`VariantStrIter`).
- **OpenCode is large.** The npm package is about 730 MB unpacked, the biggest
  single item in the image. See `pkg/ISO_SIZE_TRIM.md`.
- **No microphone is never reported.** PulseAudio always offers a capture
  device (a null source when there's no hardware), so the mic records silence
  instead of showing "No microphone found". Silent recordings aren't
  transcribed.
