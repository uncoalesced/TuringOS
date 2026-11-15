# TuringOS 1.3-stable

TuringOS 1.3-stable is the first stable release since 1.2. It carries everything from 1.3-beta (the local bridge desktop, the trust daemons, the Bazaar's signed catalogue, persistent boot) and adds the new design language, stricter checks on what the bridge and the Bazaar will trust, and a build workflow for the ISOs.

## Highlights

- New look, start to finish. The boot menus, the boot splash, the installer and the desktop now share one design language: a black room with orange used only for the one live thing on screen. The old Claude palette is gone from the UI.
- The Bazaar fails closed. If the catalogue's Ed25519 signature, the public key or `openssl` is missing, the remote index is discarded and you get the cached or bundled catalogue. npm and archive tools must carry a pinned SHA-256 or they do not install.
- The local bridge checks who is talking to it. A page must come from the bridge's own origin, and the process behind it must belong to a logged-in user. The egress allowlist is decided on the server, and plans run once.
- A fix for a black screen at login under Hyprland in a VM without 3D.
- Both ISOs can be built from GitHub Actions on native amd64 and arm64 runners.

## What changed since 1.3-beta

Added

- Design language v1.0 in `assets/design-language/`, with tokens, boards and a transparent logo.
- Boot art for isolinux and GRUB, a plymouth splash theme, and branded Calamares slides. Boot entries now read "TuringOS".
- `.github/workflows/iso.yml`, a manual workflow that builds both ISOs.
- New tests: `tests/boot_brand.sh`, `tests/kiosk_display.sh`, `trust/tests/test_local_auth.py`, and a palette guard in `tests/benchmark.sh`.
- `DOCUMENTATION.md`, a full manual.

Changed

- The web UI uses the design language tokens, and the legacy Claude palette aliases are removed.
- The plan sheet has one orange fill (Approve), an outlined "needs approval" chip with a lock, and a secondary Reject button.
- `turingos version` prints `TuringOS v1.3`.
- CI aborts a hung bridge test after 300 seconds with a stack dump.

Fixed

- The shell no longer waits forever on an XWayland that never starts; it asks `hyprctl` for the screen size and uses a 3 second timeout on every probe.
- `shell-helper` could hang once its 64 KB output cap was hit on Python 3.14.
- The plymouth label plugin is in the image, so the disk passphrase prompt is visible.

Security

- Bazaar index verification and installs fail closed, as described above. Tool keys, environment variable names and archive paths are validated.
- Bridge, shell helper and plan daemon hardening: peer and origin checks, server-side egress allowlist with no redirects and no private addresses, `reject_plan`, and single-run plans.

The full list is in [CHANGELOG.md](https://github.com/uncoalesced/TuringOS/blob/main/CHANGELOG.md).

## Downloads

| Architecture | File | Size | SHA-256 |
| :--- | :--- | :--- | :--- |
| amd64 | `turingos-amd64.hybrid.iso` | 1.89 GB (1,886,568,448 bytes) | `0f7b89fa97edcb89044d50078b26a23dd61451f59833bf9151443fb01c81c400` |
| arm64 | `turingos-arm64.hybrid.iso` | not yet published | pending |

The arm64 image is built but not yet boot-tested, so it is not attached. It will be added to this release once it has been tested.

Verify your download before you boot it. Put the ISO and `SHA256SUMS.txt` in the same folder, then run:

```bash
sha256sum -c SHA256SUMS.txt
```

Each file should report `OK`.

## Getting started

Boot the ISO in a VM or from a USB stick. The live session logs in as `user` (password `live`) and opens the desktop. To keep your changes, prepare a persistence partition with `pkg/make-persistence.sh` and boot the "TuringOS (persistence)" entry, or install to disk with the Install icon in the dock. The manual covers both: [DOCUMENTATION.md](https://github.com/uncoalesced/TuringOS/blob/main/DOCUMENTATION.md).

## Known issues

- BIOS installs and Secure Boot are untested. On arm64, Raspberry Pi bootloaders and BIOS are untested.
- The installer's "Erase disk" option makes a swap partition as large as your RAM.
- OpenCode is the largest single item on the image.
- A missing microphone is never reported: the mic records silence.

*Engineered by uncoalesced*
