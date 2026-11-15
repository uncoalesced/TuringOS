# ISO size trim

Where the image's weight goes, and how it's kept down.

## What's in place

- **Explicit package list** (`debian-live/config/package-lists/turingos.list.chroot`):
  explicit X pieces instead of the `xorg` metapackage (which pulls in every
  video driver), no unused desktop utilities.
- **Trim hooks run first.** `0200-trim` purges known bloat (office suites,
  printing, Bluetooth, modem stack, non-VM GPU drivers and firmware);
  `0300-locale-trim` keeps only English locales and drops man pages and
  `/usr/share/doc` (except copyright files and TuringOS's own docs). They run
  *before* the TuringOS hooks (0350 and later) and only remove packages nothing
  later needs.
- **Build toolchain doesn't ship.** `0450-build-daemon` installs Rust and the
  `-dev` packages, builds `turingosd`, then purges them and deletes the source.
  The runtime libraries (ALSA, libgomp) are in the package list, so they stay;
  the hook's `ldd` check fails the build if one goes missing.
- **No repo copy in the image.** `sync-scripts.sh` stages only the installed
  layout. The page is plain files and needs no build; the daemon source and the
  trust source are deleted by their hooks (0450, 0480).
- **No bundled browser engine in the UI.** The UI is a page shown in Brave, so
  the image carries no Electron or WebKitGTK shell of its own.
- **One browser: Brave.** Not in Debian, so `0420-install-brave` pulls it
  from Brave's signed apt repo (same pattern as gum in 0400) and sets it as
  `x-www-browser` and the http/https default. Chromium-based, so the Claude
  in Chrome extension works; Firefox would not (no official Anthropic
  add-on). It costs a few hundred MB unpacked; the size table below was
  measured before it was added.

## Next ideas

1. **OpenCode** is the biggest single item: about 730 MB unpacked under
   `/usr/local/lib/node_modules/opencode-ai` (0500 grows the chroot from
   3.1 GB to 4.1 GB, with Claude Code's 235 MB binary). Check whether the npm
   package ships binaries for other platforms that can be deleted, or install
   its standalone Linux binary instead.
2. Minimal bootstrap: `lb config --bootstrap-flavour minimal` pulls a base
   without the `Priority: standard` set.
3. The package list still installs `cage`, `sway` and `labwc` alongside
   Hyprland and openbox. Only Hyprland and openbox are used by the shipped
   session (`session/turingos-hyprland`); check whether the others can go.

## Sizes per build

| Build | Chroot after 0300 | After 0500 | squashfs | ISO |
|---|---|---|---|---|
| v1 (Electron, repo copy in `/opt`) | | ~4.9 GB mid-build | | |
| Tauri UI, October 2026 | 3.1 GB | 4.1 GB | 1.29 GB | 1.40 GB |
| v1.3-beta, amd64 (`release_notes_v1.3-beta.md`) | | | | 1.85 GB |
| v1.3-beta, arm64 (`release_notes_v1.3-beta.md`) | | | | 1.67 GB |
