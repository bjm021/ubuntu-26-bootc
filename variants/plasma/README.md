# ubuntu-26-bootc-plasma

A KDE Plasma desktop image built on top of `ubuntu-26-bootc`, providing a full
Plasma 6 experience with Flatpak, Firefox, and VS Code pre-installed.

This image is an example of how to extend `ubuntu-26-bootc` with additional
software. The same pattern applies further — use this image as your `FROM` base
if you need Plasma plus extra packages or configuration.

## What's included

- **KDE Plasma 6** — `plasma-desktop` with Wayland session (`plasma-session-wayland`)
- **Display manager** — SDDM with the Breeze theme
- **Apps** — Konsole, Dolphin, Kate, Okular, Gwenview, Ark, Spectacle, Yakuake
- **Firefox** — installed from the Mozilla PPA (not the snap)
- **VS Code** — from the official Microsoft repository
- **Flatpak** — with Flathub pre-seeded as a system remote
- **Discover** — limited to the Flatpak backend (system package management is
  meaningless on a bootc image; the native backend would crash on Ubuntu 26.04)
- **Mesa drivers** — `libgl1-mesa-dri`, `mesa-vulkan-drivers` (swap for NVIDIA if needed)

## Build arguments

| Argument | Default | Description |
|---|---|---|
| `LANG` | `de_DE.UTF-8` | System locale |
| `KBD_LAYOUT` | `de` | X/Wayland keyboard layout |
| `UBUNTU_USER_PASSWORD` | `ubuntu` | Password for the `ubuntu` user |
| `REMOVE_UBUNTU_USER` | `false` | Set to `true` to delete the `ubuntu` user entirely |

## OTA updates (`bootc upgrade`)

`bootc upgrade [--apply]` works on a running system from any terminal. 
