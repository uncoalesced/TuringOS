# Shipping TuringOS in a Debian ISO

How to bake TuringOS into a custom Debian ISO so it's there on first boot.

---

## Overview

Debian builds ISOs with `live-build`. The steps:

1. Build the `turingos` `.deb` package locally with `dpkg-buildpackage`
2. Put the resulting `.deb` in a local apt repo
3. Set up a `live-build` config
4. Add `turingos` to the package list
5. Point the ISO build at your local repo
6. Run `lb build`

---

## Step 1: Build the package

On a Debian (or Debian-based) machine:

```bash
cd /path/to/turingos/pkg
sudo apt install devscripts debhelper build-essential
dpkg-buildpackage -us -uc -b
```

You should get a file like:

```
../turingos_0.1.0-1_all.deb
```

---

## Step 2: Create a local apt repo

```bash
mkdir -p ~/turingos-repo
cp ../turingos_0.1.0-1_all.deb ~/turingos-repo/
cd ~/turingos-repo
sudo apt install dpkg-dev
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

---

## Step 3: Set up live-build

```bash
sudo apt install live-build
mkdir turingos-iso && cd turingos-iso
lb config --distribution bookworm --archive-areas "main"
```

---

## Step 4: Add your local repo to the ISO's apt sources

Create `config/archives/turingos-repo.list.chroot`:

```
deb [trusted=yes] file:///home/yourusername/turingos-repo ./
```

---

## Step 5: Add turingos to the package list

Create or edit `config/package-lists/turingos.list.chroot`:

```
turingos
gum
fzf
nodejs
npm
jq
btrfs-progs
libnotify-bin
```

`gum`, `fzf`, `jq`, `btrfs-progs`, and `libnotify-bin` are the runtime deps
that give the best experience. `turingos` depends on them anyway; listing them
here means they're pre-installed instead of downloaded on first run.

---

## Step 6: Build the ISO

```bash
sudo lb build
```

Expect 10–30 minutes, depending on your machine.

The ISO ends up in the current directory as `live-image-amd64.hybrid.iso`.

---

## Step 7: Test in a VM before burning

```bash
# QEMU quick test
qemu-system-x86_64 \
  -m 4G \
  -enable-kvm \
  -cdrom live-image-amd64.hybrid.iso \
  -boot d
```

Boot it, open a terminal, and check:

```bash
turingos version
turingos init
turingos help
```

---

## First boot

When the user logs in after installing from the ISO:

1. `/etc/profile.d/turingos-first-run.sh` runs on the first interactive shell
2. A welcome banner appears
3. The user runs `turingos init`. The dependency check passes because everything is already installed
4. `turingos agent start` is ready to use

---

## Updating the package

Bump the version in `debian/changelog` (use `dch -i`), rebuild with
`dpkg-buildpackage`, re-scan the local repo, then rebuild the ISO.

```bash
# In pkg/
dch -i
dpkg-buildpackage -us -uc -b
cp ../turingos_*.deb ~/turingos-repo/
cd ~/turingos-repo
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
```

---

## File layout after install

```
/usr/bin/turingos                ← main executable (in PATH)
/usr/lib/turingos/
├── core/
│   ├── config.sh
│   ├── ui.sh
│   └── logging.sh
├── agent/claude.sh
├── agent/nim.sh
├── sandbox/
│   ├── btrfs.sh
│   └── diff.sh
├── bazaar/
│   ├── registry.sh
│   ├── install.sh
│   └── registry.json
├── game/gamemode.sh
└── monitor/system.sh
/usr/share/doc/turingos/
├── WORKFLOW.md
└── plan.md
/etc/profile.d/turingos-first-run.sh
```

User data (sandboxes, logs, config) always lives in `~/.turingos/`. Package
install, upgrade, and removal never touch it.
