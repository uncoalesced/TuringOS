# Known issues

Status from booting the ISO in VMware Workstation 26 (BIOS and UEFI, 3D on and
off), October 2026. Login for debugging: `user` / `live` (live-config's
default), with passwordless sudo.

## Fixed and verified

- **Kiosk autologin.** lightdm now starts after live-config
  (`0470-autologin-kiosk`), so the boot goes straight to openbox and the
  UI with no greeter.
- **Boot menu waited for a key.** `0900-boot-timeout` starts the live entry
  after 3 seconds.
- **Blank, blurred or slow UI in VMs.** The UI no longer runs in WebKitGTK:
  it is a Brave app window. VMs without 3D (or with only llvmpipe) get
  Brave's software path and a lighter graphics level
  (`session/turingos-gfx-detect`).

- **No browser.** `claude` /login, the Anthropic Console, Google sign-in and
  UI links had nothing to open in. Brave is now the default for `xdg-open`,
  `x-www-browser` and `$BROWSER`, with the Claude extension force-installed
  by policy (`0420-install-brave`).
- **No persistent install.** Everything lived in RAM. Calamares now
  installs to disk (`0495-installer`). GRUB ships in the image, so it works
  offline.

## Open

- **OpenCode is large.** The npm package is about 730 MB unpacked, the biggest
  single item in the image. See `pkg/ISO_SIZE_TRIM.md`.
- **No microphone is never reported.** PulseAudio always offers a capture
  device (a null source when there's no hardware), so the mic records silence
  instead of showing "No microphone found". Silent recordings aren't
  transcribed.
