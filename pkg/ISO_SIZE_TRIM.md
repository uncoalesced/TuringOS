# ISO Size Trim — Next Build

v1 uses live-build default bootstrap (full Debian base) + task-xfce-desktop-equivalent
stack. Next pass: shrink by dropping unused base packages instead of a bespoke
task metapackage.

## Plan

1. Switch bootstrap from default to a minimal variant:
   ```
   lb config --bootstrap-flavour minimal
   ```
   Pulls `build-essential`-free, doc-free base instead of full `Priority: standard`.

2. Add `config/package-lists/exclude.list.chroot` style removals via
   `--apt-indices false` + explicit `Package: ...\nPin: ...\nPin-Priority: -1`
   is overkill — simpler: use `lb config --debian-installer none` (already
   not installing d-i) and purge these known-bloat packages post-install via
   a hook (`config/hooks/normal/0200-trim.hook.chroot`):
   - `task-*` metapackages not actually needed (we hand-pick X/openbox already)
   - `xserver-xorg-video-*` drivers other than `-vesa`/`-modesetting`/`-qxl`/`-vmware`
     (VM target — drop `-intel`, `-amdgpu`, `-nouveau`, `-radeon` etc.)
   - `firmware-*` blobs for hardware we don't target in a VM
     (`firmware-nvidia-graphics`, `firmware-amd-graphics`, `firmware-realtek`, etc.
     — keep only what's needed for VMware/QEMU: `firmware-linux` core only)
   - `libreoffice*`, `gnome-*-games`, printing stack (`cups*`), `bluetooth`,
     `modemmanager`, `network-manager-*-gnome` bits if not needed
   - doc/locale bloat: `apt-get install -y localepurge` and purge all locales
     except `en_US.UTF-8`, run `apt-get clean`, drop `/usr/share/doc/*`,
     `/usr/share/man/*` (already stripped somewhat by debhelper policy, but
     base image still ships them)

3. Rebuild and compare `du -sh chroot/` before/after — target noted here once
   v1's actual chroot size is known as baseline.

4. Do this as a **separate hook stage after** the brew/claude-code hook, since
   removing packages that curl/npm depend on (transitively) before those install
   would break the build. Order: install everything needed → trim what's dead
   weight → then binary/ISO packing.

## Baseline (v1, for comparison)

Chroot size during v1 build reached ~4.9G mid-build (before hooks/binary stage).
Final squashfs/ISO size to be recorded here once v1 build completes.
