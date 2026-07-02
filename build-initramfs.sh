#!/bin/sh
# Rebuilds /usr/lib/modules/$KVER/initramfs.img from scratch and re-splices the
# ostree-prepare-root hook back onto the end of it. See the Containerfile for
# why this can't just be a dracut module.
#
# Runs at initial image build time (before dracut gets diverted) and is left
# in the image at /usr/local/sbin/bootc-build-initramfs.sh so child images can
# call it again after adding a kernel module that must be present at early
# boot (e.g. a driver the root filesystem itself depends on). Modules that
# only need to be modprobe'd/udev-loaded after the real root is mounted don't
# need this — depmod plus the module being on disk is enough for those.
set -eu
set -o pipefail

# Prefer the real dracut binary saved off by dpkg-divert; fall back to the
# plain command for the first (pre-divert) run inside the base image build.
DRACUT=/usr/bin/dracut.distrib
[ -x "$DRACUT" ] || DRACUT=dracut

KVER=$(ls /usr/lib/modules/)
depmod "$KVER"
cp -f "/boot/vmlinuz-${KVER}" "/usr/lib/modules/${KVER}/vmlinuz"

"$DRACUT" --no-hostonly --force --add-drivers "btrfs" "/usr/lib/modules/${KVER}/initramfs.img" "$KVER"

EXTRA=$(mktemp -d)
chmod 755 "$EXTRA"
mkdir -p "$EXTRA/sbin" "$EXTRA/etc/systemd/system/initrd-switch-root.service.d"
install -m755 /usr/lib/dracut/modules.d/99bootc/ostree-prepare-root.sh \
              "$EXTRA/sbin/ostree-prepare-root.sh"
printf '[Service]\nExecStartPre=/sbin/ostree-prepare-root.sh\n' \
    > "$EXTRA/etc/systemd/system/initrd-switch-root.service.d/10-ostree-prepare-root.conf"
(cd "$EXTRA" && find . -mindepth 1 | sort | cpio --create --format=newc --quiet | gzip -1) \
    >> "/usr/lib/modules/${KVER}/initramfs.img"
rm -rf "$EXTRA"

chmod 0644 "/usr/lib/modules/${KVER}/initramfs.img"
