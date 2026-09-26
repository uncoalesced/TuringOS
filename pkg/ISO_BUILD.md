# Shipping ClaudeOS in a Debian ISO

How to bake ClaudeOS into a custom Debian ISO so it's available on first boot.

---

## Overview

Debian uses `live-build` for ISO builds. The process is:

1. Build the `claudeos` `.deb` package locally with `dpkg-buildpackage`
2. Place the resulting `.deb` in a local apt repo
3. Set up a `live-build` config
4. Add `claudeos` to the package list
5. Point the ISO build at your local repo
6. Run `lb build`

---

## Step 1 — Build the Package

On a Debian (or Debian-based) machine:

```bash
cd /path/to/claudeos/pkg
sudo apt install devscripts debhelper build-essential
dpkg-buildpackage -us -uc -b
```

This produces a file like:

```
../claudeos_0.1.0-1_all.deb
```

---

## Step 2 — Create a Local Apt Repo

```bash
mkdir -p ~/claudeos-repo
cp ../claudeos_0.1.0-1_all.deb ~/claudeos-repo/
cd ~/claudeos-repo
sudo apt install dpkg-dev
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

---

## Step 3 — Set Up live-build

```bash
sudo apt install live-build
mkdir claudeos-iso && cd claudeos-iso
lb config --distribution bookworm --archive-areas "main"
```

---

## Step 4 — Add Your Local Repo to the ISO's apt sources

Create `config/archives/claudeos-repo.list.chroot`:

```
deb [trusted=yes] file:///home/yourusername/claudeos-repo ./
```

---

## Step 5 — Add claudeos to the Package List

Create/edit `config/package-lists/claudeos.list.chroot`:

```
claudeos
gum
fzf
nodejs
npm
jq
btrfs-progs
libnotify-bin
```

`gum`, `fzf`, `jq`, `btrfs-progs`, and `libnotify-bin` are the runtime deps
that give the best experience. `claudeos` depends on them anyway — this
ensures they're pre-installed rather than downloaded on first run.

---

## Step 6 — Build the ISO

```bash
sudo lb build
```

This takes 10–30 minutes depending on your machine.

The output ISO lands in the current directory as `live-image-amd64.hybrid.iso`.

---

## Step 7 — Test in a VM Before Burning

```bash
# QEMU quick test
qemu-system-x86_64 \
  -m 4G \
  -enable-kvm \
  -cdrom live-image-amd64.hybrid.iso \
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

Bump the version in `debian/changelog` (use `dch -i`), rebuild with
`dpkg-buildpackage`, re-scan the local repo, rebuild the ISO.

```bash
# In pkg/
dch -i
dpkg-buildpackage -us -uc -b
cp ../claudeos_*.deb ~/claudeos-repo/
cd ~/claudeos-repo
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

---

## File Layout After Install

```
/usr/bin/claudeos                ← main executable (in PATH)
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
