# Known Issues — v1 Test Build

## Kiosk UI doesn't auto-launch on boot

**Symptom:** ISO boots to a lightdm login screen instead of skipping straight
to the fullscreen Electron UI. After manually logging in as `user`/`live`,
the desktop comes up but the TuringOS UI still doesn't appear on its own —
it only launches if you manually run:

```bash
KIOSK=1 /usr/local/bin/claudeos-ui
```

### Why a manual run is needed right now

Two layers were supposed to make this automatic, and at least one of them
isn't firing:

1. **lightdm autologin** (`/etc/lightdm/lightdm.conf.d/50-autologin.conf`,
   written by hook `0470-autologin-kiosk.hook.chroot`) should skip the login
   screen entirely and drop straight into an `openbox` session as `user`.
   Since a login prompt is still showing up, autologin isn't taking effect.

2. **openbox autostart** (`config/includes.chroot/etc/xdg/openbox/autostart`)
   is supposed to launch `claudeos-ui` a second after the session starts.
   This only runs if the session that actually starts *is* openbox — if the
   greeter falls back to a different default session, this file is never
   read at all.

So the manual command isn't a fix — it's just proof the binary and the
Electron bundle work correctly. The launch *mechanism* is what's broken.

### Plausible causes

- **Autologin race condition.** `user` is created dynamically at boot by
  `live-config` (via `/usr/lib/live/config/0030-live-debconfig_passwd`,
  which runs *after* most of the init sequence). If `lightdm` starts before
  that account exists, autologin silently fails and lightdm falls back to
  showing the normal greeter for the rest of that boot.
- **Session selection mismatch.** Logging in manually through the greeter
  uses whatever session is selected in the session-chooser dropdown, which
  may default to something other than `openbox` (e.g. a generic Xsession).
  If the running session isn't openbox, `/etc/xdg/openbox/autostart` is
  never executed.
- **Ordering with `live-config` more generally.** Live-config's own
  `/usr/lib/live/config/0100-lightdm` module configures lightdm itself at
  boot and may overwrite or race with our `50-autologin.conf` drop-in
  depending on systemd unit ordering.

### Fixes to try (next build)

1. **Force session order:** add an explicit systemd `After=`/`Wants=`
   dependency (or a `ExecStartPre` delay) so `lightdm.service` only starts
   once `live-config.service` (which creates the `user` account) has fully
   finished, not just been triggered.
2. **Verify greeter session default:** set `user-session=openbox` *and*
   make openbox the greeter's actual default in
   `/etc/lightdm/lightdm.conf.d/50-autologin.conf` isn't enough by itself —
   also check `/usr/share/xsessions/openbox.desktop` exists and is the only
   (or default) session so a manual login also lands in openbox.
3. **Bypass lightdm entirely for a true kiosk.** Since this is a
   demo/kiosk image, consider skipping lightdm altogether: use `nodm` (a
   true no-display-manager autologin daemon built for exactly this) or a
   systemd unit that does `agetty --autologin user --noclear tty1` +
   `startx` directly. This removes the whole lightdm/live-config race
   entirely.
4. **Add a fallback autostart hook** in `/home/user/.bashrc` or
   `/etc/profile.d/` that launches `claudeos-ui` on first TTY login too,
   as a safety net if the graphical autologin path fails — so at minimum
   a console login still reaches the UI.
5. **Bake explicit test credentials in** (see below) so debugging doesn't
   require the GRUB `init=/bin/bash` dance to get in at all.

---

## No usable login password

**Symptom:** Default live-config account is `user`, and Debian's live-config
sets its password to the well-known default `live`
(hash `8Ab05sVQ4LLps` in `0030-live-debconfig_passwd`). This does work for
manual login, but isn't obvious or documented anywhere in the build, and
`passwd`/`su` can't be used to change it from within a running session
without knowing the current one first (chicken-and-egg if `live` is ever
wrong for some reason).

### Fix for next build

Add a hook (or extend `0470-autologin-kiosk.hook.chroot`) that explicitly
sets a known password via `chpasswd`, run *after* live-config's own account
creation stage — or better, create the `user` account ourselves at build
time (skip relying on live-config's runtime creation) so credentials are
deterministic and documented.
