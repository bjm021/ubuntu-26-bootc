# ubuntu-26-bootc-gnome

A GNOME desktop image built on top of `ubuntu-26-bootc`. Provides
a full Ubuntu GNOME experience via `ubuntu-desktop-minimal` (with recommends)
plus `ptyxis`, `bat`, `curl`, and `git`.

This image is an example of how to extend `ubuntu-26-bootc` with additional
software. The same pattern applies further — use this image as your `FROM` base
if you need GNOME plus extra packages or configuration.

## Build arguments

| Argument | Default | Description |
|---|---|---|
| `LANG` | `de_DE.UTF-8` | System locale |
| `KBD_LAYOUT` | `de` | X/Wayland keyboard layout |
| `UBUNTU_USER_PASSWORD` | `ubuntu` | Password for the `ubuntu` user |
| `REMOVE_UBUNTU_USER` | `false` | Set to `true` to delete the `ubuntu` user entirely |

## OTA updates (`bootc upgrade`)

`bootc upgrade` works on a running system from any terminal. However:

**`bootc upgrade --apply` hangs when run from a GNOME terminal emulator.**

GNOME registers a `shutdown:block` inhibitor with systemd-logind to manage
session teardown. When `bootc upgrade --apply` triggers `systemctl reboot`
at the end, logind waits indefinitely for GNOME to release that inhibitor —
which never happens without a user-facing "save your work?" dialog.

**Workaround — use two steps instead:**

```sh
sudo bootc upgrade
sudo reboot
```

`bootc upgrade` without `--apply` stages the new deployment and exits cleanly.
A manual `reboot` then goes through GDM's normal logout flow and reboots
without any inhibitor conflict.

`bootc upgrade --apply` works fine from an SSH session (no GNOME session
involved, no block inhibitor).
