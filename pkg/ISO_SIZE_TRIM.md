# ISO size trim (next build)

v1 uses the live-build default bootstrap (full Debian base) plus a stack
equivalent to task-xfce-desktop. For the next pass we want to shrink it by
dropping unused base packages, not by writing a bespoke task metapackage.

## Plan

1. Switch the bootstrap from the default to a minimal variant:
   ```
   lb config --bootstrap-flavour minimal
   ```
   This pulls a base with no `build-essential` and no docs, instead of the full `Priority: standard` set.

2. We looked at `config/package-lists/exclude.list.chroot`-style removals via
   `--apt-indices false` plus explicit `Package: ...\nPin: ...\nPin-Priority: -1`
   entries. That's overkill. Simpler: use `lb config --debian-installer none`
   (we already don't install d-i) and purge these known-bloat packages
   post-install in a hook (`config/hooks/normal/0200-trim.hook.chroot`):
   - `task-*` metapackages we don't need (we already hand-pick X/openbox)
   - `xserver-xorg-video-*` drivers other than `-vesa`/`-modesetting`/`-qxl`/`-vmware`.
     The target is a VM, so drop `-intel`, `-amdgpu`, `-nouveau`, `-radeon` etc.
   - `firmware-*` blobs for hardware we don't target in a VM
     (`firmware-nvidia-graphics`, `firmware-amd-graphics`, `firmware-realtek`, etc.).
     Keep only what VMware/QEMU need: `firmware-linux` core only.
   - `libreoffice*`, `gnome-*-games`, the printing stack (`cups*`), `bluetooth`,
     `modemmanager`, and `network-manager-*-gnome` bits if not needed
   - Doc and locale bloat: `apt-get install -y localepurge` and purge every locale
     except `en_US.UTF-8`, run `apt-get clean`, drop `/usr/share/doc/*` and
     `/usr/share/man/*`. debhelper policy already strips some of this, but the
     base image still ships them.

3. Rebuild and compare `du -sh chroot/` before and after. We'll write the target
   here once we know v1's actual chroot size as a baseline.

4. Run the trim as a **separate hook stage after** the brew/claude-code hook.
   Removing packages that curl/npm depend on (even transitively) before those
   install would break the build. Order: install everything needed, trim the
   dead weight, then do binary/ISO packing.

## Baseline (v1, for comparison)

The chroot reached ~4.9G mid-build during v1 (before the hooks/binary stage).
We'll record the final squashfs/ISO size here once the v1 build completes.
