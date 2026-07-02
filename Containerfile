# Ubuntu 26.04 bootc image - built from scratch, no community base needed.
#
# Stage 1: compile bootc from source.
# Use ubuntu:26.04 as builder so ostree matches the version bootc requires
# (rust:latest is Debian-based and only ships ostree 2025.2; bootc needs >= 2025.3).
FROM docker.io/library/ubuntu:26.04 AS builder

RUN apt-get update && apt-get install -y \
        curl \
        git \
        pkg-config \
        build-essential \
        libostree-dev \
        libglib2.0-dev \
        libssl-dev \
        libefivar-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Rust via rustup (Ubuntu doesn't ship a recent enough rustc in apt)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
ENV PATH="/root/.cargo/bin:${PATH}"

RUN git clone https://github.com/bootc-dev/bootc.git /bootc
WORKDIR /bootc
RUN cargo build --release

# bootupd manages the EFI boot partition on ostree-based systems.
# bootc requires it at install time; it's not in Ubuntu's repos so we build it.
RUN git clone https://github.com/coreos/bootupd.git /bootupd
WORKDIR /bootupd
RUN cargo build --release

# Stage 2: final Ubuntu 26.04 image.
# Includes the bootc binary built above, plus other runtime dependencies.
FROM docker.io/library/ubuntu:26.04

# Runtime deps: ostree (bootc needs it at runtime), kernel, systemd
RUN apt-get update && apt-get install -y \
        ostree \
        libostree-1-1 \
        linux-image-generic \
        grub-efi-amd64-bin \
        grub2-common \
        systemd \
        systemd-sysv \
        fdisk \
        dosfstools \
        e2fsprogs \
        xfsprogs \
        podman \
        skopeo \
        uidmap \
        sudo \
        htop \
        vim \
        tmux \
        iproute2 \
        iputils-ping \
        network-manager \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# podman/skopeo only ever ran inside the build container, which gets its
# networking for free from the container runtime. A bootc image boots as a
# real OS on real hardware/VM NICs - nothing brings the interface up or
# resolves DNS unless something is enabled to do it. NetworkManager auto-
# manages any interface not otherwise claimed (DHCP by default, no config
# file needed) and is also what plasma-nm (KDE's network applet) expects.
#
# Ubuntu's network-manager package ships two separate mechanisms that both
# leave a plain ethernet device unmanaged, and both had to be overridden
# (confirmed via nmcli + `NetworkManager --print-config` on a live boot):
#
# 1. NetworkManager.conf: plugins=ifupdown,keyfile. The ifupdown plugin's
#    "managed" setting only controls devices *listed* in
#    /etc/network/interfaces - it does nothing for devices that aren't
#    listed there at all, which is every device in this image (no
#    netplan/cloud-init ever writes that file here). Fix: drop ifupdown and
#    use keyfile only.
# 2. /usr/lib/NetworkManager/conf.d/10-globally-managed-devices.conf ships
#    [keyfile] unmanaged-devices=*,except:type:wifi,except:type:gsm,
#    except:type:cdma - i.e. plain ethernet is excluded from keyfile
#    management too. Stock Ubuntu Desktop never hits either of these because
#    netplan writes a matching connection profile plus a runtime override
#    clearing this list; this image has neither. Fix: blank the list so
#    keyfile manages everything, matching what netplan would otherwise do.
#
# With both cleared, NM's default policy (auto-manage + auto-DHCP any wired
# device with no existing profile) applies with no further config needed.
RUN mkdir -p /etc/NetworkManager/conf.d \
    && printf '[main]\nplugins=keyfile\n\n[keyfile]\nunmanaged-devices=\n' \
         > /etc/NetworkManager/conf.d/10-plugins.conf
RUN systemctl enable NetworkManager

# bootc-image-builder uses osbuild which hardcodes the Fedora/RHEL SELinux path
# (etc/selinux/targeted/contexts/files/file_contexts) and crashes if it's absent.
# Ubuntu uses AppArmor, not SELinux, but we need the policy files present at
# build time so setfiles can run. Ubuntu's package puts them under 'default';
# we install it and expose a 'targeted' alias.
RUN apt-get update && apt-get install -y \
        selinux-policy-default \
        policycoreutils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /etc/selinux/targeted/contexts/files \
    && cp /etc/selinux/default/contexts/files/file_contexts \
          /etc/selinux/targeted/contexts/files/file_contexts

COPY --from=builder /bootc/target/release/bootc        /usr/bin/bootc
COPY --from=builder /bootupd/target/release/bootupd    /usr/bin/bootupd
# bootupd ships its own static GRUB config snippets; they're not packaged
# separately on Ubuntu so copy them from the source tree we compiled.
COPY --from=builder /bootupd/src/grub2/ /usr/lib/bootupd/grub2-static/
# Replace blscfg (not in Ubuntu's GRUB) with a pure-script BLS reader.
COPY 10_blscfg.cfg /usr/lib/bootupd/grub2-static/configs.d/10_blscfg.cfg
# bootupd calls grub2-editenv (Fedora name); Ubuntu ships it as grub-editenv.
RUN ln -sf /usr/bin/grub-editenv /usr/bin/grub2-editenv

# bootupd is a multicall binary: bootupctl is bootupd called via a different argv[0].
# bootc's supports_bootupd() check requires (1) bootupctl in PATH and
# (2) usr/lib/bootupd/updates/<component>.json in the deployment root.
#
# Use bootupd's newer /usr/lib/efi/<name>/<version>/EFI/ staging format (F44+).
# That path avoids the RPM query that the ostree-boot path requires - bootupd
# derives name/version directly from the directory structure.  grub-mkimage builds
# a self-contained grubx64.efi from Ubuntu's own GRUB modules.
RUN GRUB_VER=$(dpkg-query -W -f='${Version}' grub-efi-amd64-bin) \
    && grub-mkimage -O x86_64-efi \
        -o /tmp/grubx64.efi \
        -d /usr/lib/grub/x86_64-efi \
        -p /EFI/ubuntu \
        part_gpt part_msdos fat ext2 linux normal boot configfile \
        ls reboot echo search search_fs_uuid regexp test loadenv \
    && mkdir -p "/usr/lib/efi/grub2-efi-x64/${GRUB_VER}/EFI/ubuntu" \
    && mkdir -p "/usr/lib/efi/grub2-efi-x64/${GRUB_VER}/EFI/BOOT" \
    && cp /tmp/grubx64.efi "/usr/lib/efi/grub2-efi-x64/${GRUB_VER}/EFI/ubuntu/grubx64.efi" \
    && cp /tmp/grubx64.efi "/usr/lib/efi/grub2-efi-x64/${GRUB_VER}/EFI/ubuntu/shimx64.efi" \
    && cp /tmp/grubx64.efi "/usr/lib/efi/grub2-efi-x64/${GRUB_VER}/EFI/BOOT/BOOTX64.EFI" \
    && /usr/bin/bootupd generate-update-metadata \
    && ln -sf /usr/bin/bootupd /usr/bin/bootupctl

# bootc (via ChrootCmd) bind-mounts /sysroot inside the deployment chroot to
# give bootupd access to the physical root's block devices.  Ubuntu's root
# directory is 0555, so create the directory now; create_dir_all on an
# existing directory is a no-op and won't hit the EPERM.
RUN mkdir -p /sysroot

# bootc install checks for ostree/prepare-root.conf; Ubuntu's ostree package
# doesn't ship it, so create a minimal one manually.
RUN mkdir -p /usr/lib/ostree \
    && printf '[composefs]\nenabled=maybe\n' > /usr/lib/ostree/prepare-root.conf

# /run/ostree-booted must exist on the live system so that bootc, ostree CLI,
# and libostree recognise this as an ostree-booted deployment.  The real
# ostree-prepare-root binary creates it, but our shell replacement runs in the
# initramfs - and /run is a fresh tmpfs after switch_root, so anything written
# there is gone by the time the real system starts.  A tmpfiles.d snippet is
# the correct place: systemd-tmpfiles-setup.service applies it early in every
# boot from the real root.
RUN printf 'f /run/ostree-booted 0444 root root -\n' \
      > /usr/lib/tmpfiles.d/ostree-booted.conf

# Ubuntu's ostree package does not ship ostree-prepare-root or any initramfs
# hook.  Ubuntu 26.04's dracut (110-11) has a packaging bug: initramfs scripts
# reference /lib/dracut-lib.sh which doesn't exist, so run_hookd() is never
# defined and dracut's hook directories (pre-pivot, mount, etc.) are dead -
# stubbing the library back in is worse, since it makes dracut-mount actually
# execute its standard mount hooks, which call emergency_shell() and hang.
#
# A standalone systemd service enabled via a target.wants/ symlink was also
# tried and verified to be correctly placed in the initramfs (cpio contents
# inspected directly), but systemd never picked it up - no "Starting" or
# even a condition-skipped log line appeared for it, meaning the unit was
# never entered into the boot transaction at all.
#
# Most reliable option: drop an ExecStartPre= onto initrd-switch-root.service
# itself via a .d/ override.  That unit is unconditionally started every
# boot (confirmed in serial logs), so a drop-in on it sidesteps any
# uncertainty about whether our own unit gets pulled into the transaction.
#
# Strategy: build a standard dracut initramfs (which provides virtio drivers,
# UUID-based root mounting, and systemd-in-initrd), then APPEND a second
# cpio archive containing the script + the drop-in.  The Linux kernel
# supports multiple concatenated cpio archives and merges them in order -
# this avoids extracting and repacking the entire initramfs.
COPY ostree-pivot.sh /usr/lib/dracut/modules.d/99bootc/ostree-prepare-root.sh
RUN chmod +x /usr/lib/dracut/modules.d/99bootc/ostree-prepare-root.sh
# cpio is needed to append a second archive to the dracut initramfs.
RUN apt-get update && apt-get install -y --no-install-recommends cpio \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ostree's kernel discovery requires /usr/lib/modules/<kver>/vmlinuz and
# initramfs.img.
RUN echo 'force_drivers+=" btrfs "' > /etc/dracut.conf.d/btrfs.conf

COPY build-initramfs.sh /usr/local/sbin/bootc-build-initramfs.sh
RUN chmod +x /usr/local/sbin/bootc-build-initramfs.sh \
    && /usr/local/sbin/bootc-build-initramfs.sh

# The ostree-prepare-root hook above is spliced onto the end of the dracut
# output as a raw second cpio archive, bypassing dracut's own (broken, see
# above) module system entirely. dracut has no idea it's there. If any later
# layer's apt transaction fires a kernel/initramfs dpkg trigger (e.g. a
# keyboard/console package reconfiguring on top of plasma-desktop), a plain
# `dracut`/`update-initramfs` re-run silently produces a "clean" image with
# the hook gone and no error - and Ubuntu's default 0600 perms on that fresh
# image also break bootc-image-builder's `lsinitrd` introspection step later.
# Neuter both binaries so nothing downstream can regenerate this file by
# accident. Child images that install a kernel module needed at early boot
# (rare - most modules just need depmod + modprobe/udev after real root is
# mounted, not a spot in the initramfs) can still rebuild it on purpose by
# running /usr/local/sbin/bootc-build-initramfs.sh, which uses the real
# dracut saved off below and re-applies the ostree hook every time.
RUN dpkg-divert --local --rename --add /usr/bin/dracut \
    && ln -sf /bin/true /usr/bin/dracut \
    && if [ -e /usr/sbin/update-initramfs ]; then \
           dpkg-divert --local --rename --add /usr/sbin/update-initramfs \
           && ln -sf /bin/true /usr/sbin/update-initramfs; \
       fi

# skopeo (used by bootc's containers-image-proxy for imgstorage) requires
# /etc/containers/policy.json - without it skopeo immediately exits ENOENT.
# Also provide registries.conf so it knows where to search for images.
RUN mkdir -p /etc/containers \
    && printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' \
         > /etc/containers/policy.json \
    && printf 'unqualified-search-registries = ["docker.io"]\n' \
         > /etc/containers/registries.conf \
    && printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' \
         > /etc/containers/storage.conf

# Mark this as a bootc image - bootc-image-builder refuses to process images
# without this label.
LABEL containers.bootc=1

# Install user tools (shell, editor, build tools, etc.) and clean up apt cache to reduce image size.
RUN apt-get update && apt-get install -y \
        bash \
        bash-completion \
        curl \
        git \
        htop \
        nano \
        tmux \
        vim \
        less \
        sudo \
        build-essential \
        pkg-config \
        libostree-dev \
        libglib2.0-dev \
        libssl-dev \
        libefivar-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# DEBUG: add testuser:test with passwordless sudo access for testing.  Remove in production.
RUN useradd -m -s /bin/bash testuser \
    && echo 'testuser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN echo 'testuser:test' | chpasswd
