# Known issues (v1 test build)

## Kiosk UI doesn't auto-launch on boot

Symptom: the ISO boots to a lightdm login screen instead of going straight
to the fullscreen Electron UI. After logging in manually as `user`/`live`,
the desktop comes up, but the TuringOS UI still doesn't appear. It only
launches if you run this by hand:

```bash
KIOSK=1 /usr/local/bin/claudeos-ui
```

### Why a manual run is needed right now

Two layers were supposed to make this automatic. At least one of them
isn't firing.

1. **lightdm autologin** (`/etc/lightdm/lightdm.conf.d/50-autologin.conf`,
   written by hook `0470-autologin-kiosk.hook.chroot`) should skip the login
   screen and drop straight into an `openbox` session as `user`. We still
   get a login prompt, so autologin isn't taking effect.

2. **openbox autostart** (`config/includes.chroot/etc/xdg/openbox/autostart`)
   should launch `claudeos-ui` a second after the session starts. It only
   runs if the session that actually starts *is* openbox. If the greeter
   falls back to some other default session, this file is never read.

So the manual command isn't a fix. It only proves the binary and the
Electron bundle work. The launch *mechanism* is what's broken.

### Plausible causes

- **Autologin race.** `live-config` creates `user` dynamically at boot
  (via `/usr/lib/live/config/0030-live-debconfig_passwd`, which runs *after*
  most of the init sequence). If `lightdm` starts before that account
  exists, autologin fails silently and lightdm shows the normal greeter
  for the rest of that boot.
- **Session selection mismatch.** A manual login through the greeter uses
  whatever session is selected in the session-chooser dropdown, and that
  may default to something other than `openbox` (a generic Xsession, say).
  If the running session isn't openbox, `/etc/xdg/openbox/autostart` never
  runs.
- **Ordering with `live-config` in general.** Live-config's own
  `/usr/lib/live/config/0100-lightdm` module configures lightdm at boot
  and may overwrite or race with our `50-autologin.conf` drop-in,
  depending on systemd unit ordering.

### Fixes to try (next build)

1. **Force the order.** Add an explicit systemd `After=`/`Wants=`
   dependency (or an `ExecStartPre` delay) so `lightdm.service` only starts
   once `live-config.service` (which creates the `user` account) has
   finished, not just been triggered.
2. **Check the greeter's default session.** Setting `user-session=openbox`
   in `/etc/lightdm/lightdm.conf.d/50-autologin.conf` isn't enough on its
   own. Also check that `/usr/share/xsessions/openbox.desktop` exists and
   is the only (or default) session, so a manual login lands in openbox
   too.
3. **Drop lightdm for a true kiosk.** This is a demo/kiosk image, so we
   could skip lightdm altogether: use `nodm` (a no-display-manager
   autologin daemon built for this case) or a systemd unit that runs
   `agetty --autologin user --noclear tty1` + `startx` directly. That
   removes the lightdm/live-config race completely.
4. **Add a fallback autostart** in `/home/user/.bashrc` or
   `/etc/profile.d/` that launches `claudeos-ui` on first TTY login too.
   If the graphical autologin path fails, a console login still reaches
   the UI.
5. **Bake in explicit test credentials** (see below) so debugging doesn't
   need the GRUB `init=/bin/bash` dance just to get in.

---

## No usable login password

Symptom: the default live-config account is `user`, and Debian's live-config
sets its password to the well-known default `live`
(hash `8Ab05sVQ4LLps` in `0030-live-debconfig_passwd`). That works for
manual login, but nothing in the build makes it obvious or documents it.
You also can't use `passwd`/`su` to change it from a running session
without knowing the current password first, which is a chicken-and-egg
problem if `live` is ever wrong for some reason.

### Fix for next build

Add a hook (or extend `0470-autologin-kiosk.hook.chroot`) that sets a known
password with `chpasswd`, run *after* live-config's own account creation
stage. Better still, create the `user` account ourselves at build time
instead of relying on live-config's runtime creation, so the credentials
are deterministic and documented.
