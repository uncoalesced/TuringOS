# Shipping ClaudeOS in the CachyOS ISO

How to bake ClaudeOS into a custom CachyOS ISO so it's available on first boot.

---

## Overview

CachyOS uses `archiso` for ISO builds. The process is:

1. Build the `claudeos` package locally with `makepkg`
2. Place the resulting `.pkg.tar.zst` in a local pacman repo
3. Clone the CachyOS ISO build repo
4. Add `claudeos` to the ISO package list
5. Point the ISO build at your local repo
6. Run `mkarchiso`

---

## Step 1 — Build the Package

On a CachyOS or Arch Linux machine:

```bash
cd /path/to/claudeos/pkg
makepkg -si
```

`-s` installs missing dependencies, `-i` installs the built package.

This produces a file like:

```
claudeos-0.1.0-1-any.pkg.tar.zst
```

To build without installing:

```bash
makepkg -s
```

---

## Step 2 — Create a Local Pacman Repo

```bash
mkdir -p ~/claudeos-repo
cp claudeos-0.1.0-1-any.pkg.tar.zst ~/claudeos-repo/
cd ~/claudeos-repo
repo-add claudeos-repo.db.tar.gz claudeos-0.1.0-1-any.pkg.tar.zst
```

---

## Step 3 — Clone the CachyOS ISO Build Repo

```bash
git clone https://github.com/CachyOS/cachyos-iso.git
cd cachyos-iso
```

---

## Step 4 — Add Your Local Repo to the ISO pacman.conf

Edit the pacman config used by the ISO build.  
The file is typically at `cachyos-iso/airootfs/etc/pacman.conf` or
passed via the profile's `pacman.conf`.

Add at the top (before `[core]`):

```ini
[claudeos-repo]
SigLevel = Optional TrustAll
Server = file:///home/yourusername/claudeos-repo
```

---

## Step 5 — Add claudeos to the Package List

Find the package list file. In CachyOS ISO profiles it's usually:

```
cachyos-iso/packages.x86_64
```

Add these lines:

```
claudeos
gum
fzf
nodejs
npm
jq
btrfs-progs
libnotify
```

`gum`, `fzf`, `jq`, `btrfs-progs`, and `libnotify` are the runtime deps that
give the best experience. `claudeos` depends on them anyway — this ensures
they're pre-installed rather than downloaded on first run.

---

## Step 6 — Build the ISO

```bash
sudo mkarchiso -v -w /tmp/archiso-work -o /tmp/archiso-out ./cachyos-iso
```

This takes 5–20 minutes depending on your machine.

The output ISO lands in `/tmp/archiso-out/`.

---

## Step 7 — Test in a VM Before Burning

```bash
# QEMU quick test
qemu-system-x86_64 \
  -m 4G \
  -enable-kvm \
  -cdrom /tmp/archiso-out/cachyos-*.iso \
  -boot d
```

Boot it, open a terminal, and verify:

```bash
claudeos version
claudeos init
claudeos help
```

---

## First Boot Experience

When the user logs in after installing from the ISO:

1. `/etc/profile.d/claudeos-first-run.sh` fires on the first interactive shell
2. A welcome banner is shown
3. User runs `claudeos init` — dependency check passes because everything is pre-installed
4. `claudeos agent start` is ready to use

---

## Updating the Package

Bump `pkgver` and `pkgrel` in `PKGBUILD`, rebuild with `makepkg`, re-add to the
local repo with `repo-add`, rebuild the ISO.

```bash
# In pkg/
makepkg -s
cd ~/claudeos-repo
repo-add claudeos-repo.db.tar.gz claudeos-0.1.0-2-any.pkg.tar.zst
```

---

## File Layout After Install

```
/usr/local/bin/claudeos          ← main executable (in PATH)
/usr/lib/claudeos/
├── core/
│   ├── config.sh
│   ├── ui.sh
│   └── logging.sh
├── agent/claude.sh
├── sandbox/
│   ├── btrfs.sh
│   └── diff.sh
├── bazaar/
│   ├── registry.sh
│   ├── install.sh
│   └── registry.json
├── game/gamemode.sh
└── monitor/system.sh
/usr/share/doc/claudeos/
├── WORKFLOW.md
└── plan.md
/etc/profile.d/claudeos-first-run.sh
```

User data (sandboxes, logs, config) always lives in `~/.claudeos/` — never
touched by package install, upgrade, or removal.
