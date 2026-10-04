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

## Open

- **No browser in the image — fixed in the build, awaiting boot re-test.**
  `0420-install-brave` installs `brave-browser-stable` from Brave's signed
  apt repo, registers it as `x-www-browser` (the dock's Browser button) and
  the system `http`/`https` mime default (`/etc/xdg/mimeapps.list`), and fails
  the build if either is missing. Brave is Chromium-based, so the Claude in
  Chrome extension works (Firefox has no official Anthropic add-on). Re-test
  after the next build: click a link in the UI and run
  `xdg-open https://example.com` as `user`.
- **`glib` 0.18 Dependabot alert.** Tauri's GTK 0.18 stack pins it; nothing to
  upgrade to until Tauri moves to gtk-rs 0.20+. TuringOS's own code doesn't
  call the affected API (`VariantStrIter`).
- **OpenCode is large.** The npm package is about 730 MB unpacked, the biggest
  single item in the image. See `pkg/ISO_SIZE_TRIM.md`.
- **No microphone is never reported.** PulseAudio always offers a capture
  device (a null source when there's no hardware), so the mic records silence
  instead of showing "No microphone found". Silent recordings aren't
  transcribed.
