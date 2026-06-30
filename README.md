# ubuntu-26-bootc

A [bootc](https://github.com/bootc-dev/bootc) image built on **Ubuntu 26.04**,
assembled from scratch. No community Ubuntu bootc base image exists yet, so
this handles all the plumbing normally provided by a distro's first-class bootc
support.

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
  GRUB-script reimplementation: it reads the BLS entry at
  `/loader/entries/ostree-1.conf`, extracts the deployment hash and kernel
  version, and constructs the boot `menuentry` by hand. It is installed into
  bootupd's static GRUB config snippets directory, which bootupd concatenates
  into the final `grub.cfg` at install time.

- **`ostree-pivot.sh`** — pure POSIX shell pivot script run inside the
  initramfs. Ubuntu's `ostree` package doesn't ship the `ostree-prepare-root`
  binary that real ostree-based distros provide, so this replaces it. It reads
  `ostree=` from the kernel command line, resolves the deployment symlink under
  `/sysroot`, bind-mounts persistent `/var`, and bind-mounts the deployment
  directory over `/sysroot` so `initrd-switch-root.service` pivots into the
  correct ostree root. Progress is logged to `/dev/kmsg`.

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
unconditionally started every boot. The `Containerfile` appends a small second
cpio archive (script + drop-in) to the end of the dracut-generated
`initramfs.img` — the Linux kernel natively supports concatenated cpio archives
and merges them in order, avoiding a full extract-and-repack.

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
  ship one; `bootc install` requires it. `composefs` is set to `enabled=maybe`
  since composefs may not be available in all kernels.
- **`/etc/containers/policy.json`**: skopeo (used by bootc's image proxy) exits
  immediately without a policy file.

## Building

```sh
podman build -t ubuntu-26-bootc .
```

## Converting to a disk image

Requires rootful podman (bootc-image-builder uses rootful storage internally):

```sh
sudo podman run --rm \
    --privileged \
    --pull=newer \
    -v /var/lib/containers/storage:/var/lib/containers/storage \
    -v "$PWD/output:/output" \
    quay.io/centos-bootc/bootc-image-builder:latest \
    --type qcow2 \
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
