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
  *before* the TuringOS hooks (0400+) and only remove packages nothing later
  needs.
- **Build toolchain doesn't ship.** `0450-build-ui` installs Rust and the
  `-dev` packages, builds the UI, then purges them. The UI's runtime
  libraries are in the package list, so they stay; the hook's `ldd` check
  fails the build if one goes missing.
- **No repo copy in the image.** `sync-scripts.sh` stages only the installed
  layout; the UI source is deleted after the build.
- **Electron is gone.** The UI uses the system WebKitGTK instead of bundling
  Chromium (about 250 MB less).

## Next ideas

1. **OpenCode** is the biggest single item: about 730 MB unpacked under
   `/usr/local/lib/node_modules/opencode-ai` (0500 grows the chroot from
   3.1 GB to 4.1 GB, with Claude Code's 235 MB binary). Check whether the npm
   package ships binaries for other platforms that can be deleted, or install
   its standalone Linux binary instead.
2. Minimal bootstrap: `lb config --bootstrap-flavour minimal` pulls a base
   without the `Priority: standard` set.

## Sizes per build

| Build | Chroot after 0300 | After 0500 | squashfs | ISO |
|---|---|---|---|---|
| v1 (Electron, repo copy in `/opt`) | | ~4.9 GB mid-build | | |
| Tauri UI, October 2026 | 3.1 GB | 4.1 GB | 1.29 GB | 1.40 GB |
