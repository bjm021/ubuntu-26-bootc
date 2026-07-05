# bootc/ubuntu-26

A [bootc](https://github.com/bootc-dev/bootc) image built on **Ubuntu 26.04**,
assembled from scratch. The one community Ubuntu bootc project,
[bootcrew/ubuntu-bootc](https://github.com/bootcrew/ubuntu-bootc), is now
archived (merged into `bootcrew/mono`) and only ever covered building and
booting once — it doesn't handle OTA upgrades, `ostree-finalize-staged`, or
the NetworkManager/initramfs plumbing a real deployment needs. This image
handles all of that, since no distro-provided first-class bootc support
exists for Ubuntu.

## Files

- **`Containerfile`** — two-stage build.
  - Stage 1 (`builder`): compiles `bootc` and `bootupd` from source against
    Ubuntu's `libostree-dev`. The builder must be `ubuntu:26.04` (not a Rust
    base image) because Debian-based images ship an older ostree that bootc
    rejects.
  - Stage 2: installs runtime deps (ostree, kernel, GRUB, systemd, podman),
    copies in the compiled binaries, and applies the workarounds below.

- **`10_blscfg.cfg`** — replacement for GRUB's `blscfg` module. Ubuntu's
  `grub-efi-amd64-bin` doesn't ship `blscfg.mod`, so this is a pure
  GRUB-script reimplementation. After `bootc upgrade`, ostree writes two BLS
  entries: `ostree-2.conf` (pending/new deployment) and `ostree-1.conf`
  (rollback/current). The script prefers `ostree-2.conf` when present so the
  next boot activates the new deployment, falling back to `ostree-1.conf`
  otherwise. The hash regexp matches any serial number (`/[0-9]+` not the
  hardcoded `/0`) because the serial increments with each upgrade. It is
  installed into bootupd's static GRUB config snippets directory, which
  bootupd concatenates into the final `grub.cfg` at install time.

- **`ostree-pivot.sh`** — pure POSIX shell pivot script run inside the
  initramfs. Ubuntu's `ostree` package doesn't ship the `ostree-prepare-root`
  binary that real ostree-based distros provide, so this replaces it,
  following the same staged-mount approach as upstream's
  `src/switchroot/ostree-prepare-root.c` (verified against its source). It
  reads `ostree=` from the kernel command line, resolves the deployment
  symlink under `/sysroot`, then assembles the new root at a temporary
  `/sysroot.tmp` mountpoint: bind-mounts the deployment there, bind-mounts
  `/etc` onto itself (writable) and `/usr` onto itself then remounts it
  read-only — Ubuntu is usr-merged, so this one directory covers effectively
  the whole OS payload, same as Fedora/CoreOS — and bind-mounts the
  persistent stateroot `/var` in. Only once all of that is assembled does it
  `mount --move` the staging tree onto `/sysroot` so
  `initrd-switch-root.service` pivots into the correct, now-immutable ostree
  root. Progress is logged to `/dev/kmsg`.

  The staging step matters: an earlier version bind-mounted the deployment
  directly over `/sysroot`, and separately bind-mounted persistent `/var`
  onto `/sysroot/var` beforehand. Confirmed via an `unshare --mount` sandbox
  test that this ordering silently shadows the `/var` bind-mount once the
  deployment lands on top of it — `/var` would reset to the deployment's own
  empty directory on every boot instead of persisting. Assembling everything
  at a separate mountpoint first and moving it into place atomically (what
  upstream does) avoids this.

## Why the initramfs needs patching

Ubuntu 26.04's `dracut` (110-11) has a packaging bug: initramfs scripts source
`/lib/dracut-lib.sh`, but that file isn't present in the generated initramfs.
Without it, `run_hookd()` is never defined and dracut's entire hook system
(`pre-pivot`, `mount`, etc.) is silently dead — so there's no way to inject an
ostree activation step via the normal dracut module mechanism.

Two other approaches were tried and ruled out before the current one:

- **Stubbing `/lib/dracut-lib.sh` back in**: defining `run_hookd()` re-enables
  hook execution, but it also wakes up `dracut-mount.service`'s standard mount
  hooks for the first time. Those hooks call `emergency_shell()`, which isn't
  implemented in this environment, causing an infinite tight-looped crash.
- **A standalone systemd service** with an `initrd-root-fs.target.wants/`
  symlink: the cpio contents were verified correct (extracted and inspected
  directly from the built image), but systemd never pulled the unit into the
  boot transaction — not even a condition-skipped log line appeared.

**What works**: a drop-in override on `initrd-switch-root.service` via
`/etc/systemd/system/initrd-switch-root.service.d/10-ostree-prepare-root.conf`
adding `ExecStartPre=/sbin/ostree-prepare-root.sh`. That unit is
unconditionally started every boot. `build-initramfs.sh` appends a small second
cpio archive (script + drop-in) to the end of the dracut-generated
`initramfs.img` — the Linux kernel natively supports concatenated cpio archives
and merges them in order, avoiding a full extract-and-repack.

Because dracut has no idea this second archive exists, any later `dracut` /
`update-initramfs` run (e.g. a dpkg trigger fired by a package in a child
image) would silently regenerate a "clean" `initramfs.img` with the hook gone
— no error, just a system that no longer boots. The `Containerfile` guards
against this by `dpkg-divert`-ing both binaries to no-ops right after the
initramfs is built, so nothing downstream can regenerate it by accident.

If a child image needs to add a kernel module that must be present at early
boot (rare — most modules just need `depmod` plus `modprobe`/udev after the
real root is mounted, not a spot in the initramfs), it can rebuild it on
purpose by running `/usr/local/sbin/bootc-build-initramfs.sh`, which is left
in the image, uses the real dracut binary saved off by the divert, and
re-applies the ostree hook every time it runs.

## Other workarounds

- **bootupd EFI staging**: `grubx64.efi` is built via `grub-mkimage` from
  Ubuntu's own GRUB modules. It's installed as both `grubx64.efi` / `shimx64.efi`
  / `BOOTX64.EFI` since this build does no real Secure Boot shim signing.
- **`grub2-editenv` symlink**: bootupd calls the Fedora binary name; Ubuntu
  ships it as `grub-editenv`.
- **SELinux policy stub**: `bootc-image-builder`'s osbuild backend hardcodes a
  Fedora/RHEL SELinux path. Ubuntu uses AppArmor, but the policy files must
  exist at build time so `setfiles` doesn't crash. `selinux-policy-default` is
  installed and aliased to the `targeted` path osbuild expects.
- **`/usr/lib/ostree/prepare-root.conf`**: Ubuntu's `ostree` package doesn't
  ship one; `bootc install` requires it. `composefs` is set to `enabled=no`
  to skip EROFS image generation (faster deployment checkout).
- **`/etc/containers/policy.json`**: skopeo (used by bootc's image proxy) exits
  immediately without a policy file.
- **`network-manager` + `/etc/NetworkManager/conf.d/10-plugins.conf`**:
  `podman build`/`podman run` get networking for free from the container
  runtime, but a booted bootc image is a real OS on a real NIC with no DHCP
  client otherwise. Installing `network-manager` and enabling
  `NetworkManager.service` isn't enough by itself, though — Ubuntu's package
  ships two separate defaults that both leave plain ethernet devices
  unmanaged (confirmed live via `nmcli` + `NetworkManager --print-config`):
  `NetworkManager.conf`'s `plugins=ifupdown,keyfile` (the `ifupdown` plugin's
  `managed` setting only applies to devices *listed* in
  `/etc/network/interfaces`, which nothing in this image ever writes), and
  `/usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf`'s
  `unmanaged-devices=*,except:type:wifi,except:type:gsm,except:type:cdma`
  (excludes plain ethernet from `keyfile` management too). Stock Ubuntu
  Desktop never hits either because netplan writes a matching connection
  profile plus a runtime override clearing that list; this image has no
  netplan, so `10-plugins.conf` does the same job by hand: drops `ifupdown`
  (`plugins=keyfile`) and blanks `unmanaged-devices=`. With both cleared,
  NM's default policy (auto-manage + auto-DHCP any wired device with no
  existing profile) takes over with no further config needed.

- **`bubblewrap`**: installed explicitly because Ubuntu's image carries SELinux
  policy files (from `selinux-policy-default`, needed by `bootc-image-builder`).
  `ostree admin finalize-staged` detects these and calls `/usr/bin/bwrap` for
  the SELinux relabeling step even when SELinux is `Disabled`. Without the
  package the finalize-staged run fails with a `bwrap: No such file` error.

- **`ostree-finalize-staged.service`**: Ubuntu's `ostree` package doesn't ship
  this unit; without it `bootc upgrade` exits with code 5. Three interlocking
  issues required workarounds:
  1. *Lock deadlock*: libostree holds the sysroot lock while calling
     `systemctl start ostree-finalize-staged` synchronously. Our
     `finalize-staged` also needs that lock. Fix: the service wrapper detects
     `bootc` via `pgrep`, exits 0 immediately (releasing the systemctl call),
     and hands off the actual work to a background helper.
  2. *`--apply` race*: `bootc upgrade --apply` triggers a reboot right after
     the service exits, killing the background helper before it can complete.
     Fix: the helper is wrapped in `systemd-inhibit --mode=delay` so the
     reboot is postponed until `ostree admin finalize-staged` finishes.
  3. *Lock still held at reboot*: bootc holds the sysroot lock while blocking
     on `systemctl reboot`, preventing finalize-staged from acquiring it. Fix:
     bootc is patched at build time (the source is compiled from scratch) to
     call `sysroot.unlock()` before the reboot call inside `async fn upgrade`.

- **`InhibitDelayMaxSec=120`** in `/etc/systemd/logind.conf.d/inhibit-delay.conf`:
  raises systemd-logind's shutdown delay cap from the default 5 s to 120 s so
  the inhibitor held by the finalize-staged helper has enough time to complete
  before the reboot proceeds.

## OTA updates (`bootc upgrade`)

`bootc upgrade` and `bootc upgrade --check` work on a running system. The image
is pulled from whatever registry was used at install time (recorded in
`/sysroot/ostree/deploy/default/deploy/*.origin`).

**Registry must be HTTPS in production.** The image's `/etc/containers/registries.conf`
only lists `docker.io` as an unqualified search registry. If you're pulling from
a plain-HTTP dev registry (e.g. the local one started by `make registry-start`),
you need to add an insecure entry on each deployed machine:

```sh
cat >> /etc/containers/registries.conf << 'EOF'

[[registry]]
location = "192.168.1.15:5000"
insecure = true
EOF
```

Do **not** bake this into the image — in production the registry should terminate
TLS, and an `insecure = true` entry in the shipped image would silently bypass
certificate validation for anyone using that address.

## Building

```sh
podman build -t ubuntu-26-bootc .
```

## Converting to a disk image

Requires rootful podman (bootc-image-builder uses rootful storage internally).

The default 10GiB root partition is too small for this image — the unpacked
content plus podman's own imgstorage copy runs past the free-space margin
ostree requires — so request a larger one via a disk customization config:

```sh
cat > /tmp/bootc-builder-config.toml << 'EOF'
[[customizations.filesystem]]
mountpoint = "/"
minsize = 21474836480
EOF

sudo podman run --rm \
    --privileged \
    --pull=newer \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$PWD/output:/output" \
    -v /tmp/bootc-builder-config.toml:/config.toml \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
    --config /config.toml \
    --local \
    ubuntu-26-bootc
# disk image is written to ./output/qcow2/disk.qcow2
```

## Booting in QEMU

```sh
qemu-system-x86_64 \
    -machine type=q35 \
    -cpu host -enable-kvm \
    -m 2048 \
    -smp 2 \
    -drive if=virtio,format=qcow2,file=output/qcow2/disk.qcow2 \
    -bios /usr/share/ovmf/x64/OVMF.fd \
    -display gtk,zoom-to-fit=on \
    -device virtio-vga \
    -serial stdio
```

Adjust `-bios` to the OVMF firmware path on your system (common locations:
`/usr/share/edk2/x64/OVMF.fd` on Arch, `/usr/share/OVMF/OVMF_CODE.fd` on
Debian/Ubuntu). Remove `-enable-kvm` if KVM is unavailable.
