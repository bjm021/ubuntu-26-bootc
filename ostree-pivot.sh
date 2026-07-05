#!/bin/sh
# Dracut pre-pivot hook: activate the ostree deployment before switch_root.
# Pure shell, no binary deps. Output goes to /dev/kmsg (appears in serial log).

log() { echo "<6>ostree-pivot: $*" > /dev/kmsg 2>/dev/null || echo "ostree-pivot: $*"; }
err() { echo "<3>ostree-pivot: ERROR: $*" > /dev/kmsg 2>/dev/null || echo "ostree-pivot: ERROR: $*"; }

[ -f /lib/dracut-lib.sh ] && . /lib/dracut-lib.sh 2>/dev/null
type getarg >/dev/null 2>&1 || getarg() {
    local _k="${1%=}" _a
    for _a in $(cat /proc/cmdline 2>/dev/null); do
        case "$_a" in "${_k}="*) printf '%s\n' "${_a#*=}"; return 0;; esac
    done
    return 1
}

log "hook started"

OSTREE=$(getarg ostree=) || { log "no ostree= arg, skipping"; exit 0; }
[ -n "$OSTREE" ] || { log "ostree= is empty, skipping"; exit 0; }

SYSROOT=/sysroot
STAGING=/sysroot.tmp
[ -d "$SYSROOT/ostree" ] || { err "no /sysroot/ostree — sysroot not mounted?"; exit 1; }

log "activating $OSTREE"

# Resolve the deployment symlink chain under /sysroot
DEPLOY=$(readlink -f "${SYSROOT}${OSTREE}" 2>/dev/null)
if [ -z "$DEPLOY" ] || [ ! -d "$DEPLOY" ]; then
    err "cannot resolve deployment ${SYSROOT}${OSTREE}"
    exit 1
fi
log "deployment: ${DEPLOY#$SYSROOT}"

# Persistent var: .../ostree/deploy/OSNAME/var
OSNAME=$(printf '%s' "$DEPLOY" | sed 's|.*/ostree/deploy/\([^/]*\)/deploy/.*|\1|')
VAR_SRC="${SYSROOT}/ostree/deploy/${OSNAME}/var"
log "osname=$OSNAME var=$VAR_SRC"

# Write /run/ostree-booted as a GVariant a{sv} dict so that libostree 2025.x
# can identify the booted deployment.  libostree reads this file and compares
# the stored (dev, ino) with each deployment directory's stat to find which
# deployment is currently booted.  Without this file (or with an empty one as
# created by tmpfiles.d), bootc status fails with "bootloader entry not found"
# when composefs is active because stat("/") returns the overlay device number,
# which does not match any deployment directory.
#
# The /run tmpfs is preserved by systemd across switch_root, so this file is
# accessible in the running system.
#
# Binary layout: GVariant a{sv} with one entry:
#   key  = "backing-root-device-inode" (string, 26 bytes including NUL)
#   pad  = 6 zero bytes (align variant v to 8)
#   val  = GVariant v containing (tt) = (deploy_dev, deploy_ino):
#            16-byte body + 1-byte NUL + 4-byte type string "(tt)"
#   {sv} framing offset: 26 = 0x1a  (end of key string)
#   a{sv} framing offset: 54 = 0x36 (end of {sv} element)
#   Total: 55 bytes
_ddev=$(stat -c '%d' "$DEPLOY" 2>/dev/null) || _ddev=""
_dino=$(stat -c '%i' "$DEPLOY" 2>/dev/null) || _dino=""
if [ -n "$_ddev" ] && [ -n "$_dino" ]; then
    {
        printf 'backing-root-device-inode'
        printf '\000'                        # NUL-terminate key string (byte 25)
        printf '\000\000\000\000\000\000'   # 6-byte alignment padding (bytes 26-31)
        # deploy_dev as uint64 LE (bytes 32-39)
        printf "\\$(printf '%03o' $((_ddev&0xff)))\\$(printf '%03o' $(((_ddev>>8)&0xff)))\\$(printf '%03o' $(((_ddev>>16)&0xff)))\\$(printf '%03o' $(((_ddev>>24)&0xff)))\\000\\000\\000\\000"
        # deploy_ino as uint64 LE (bytes 40-47)
        printf "\\$(printf '%03o' $((_dino&0xff)))\\$(printf '%03o' $(((_dino>>8)&0xff)))\\$(printf '%03o' $(((_dino>>16)&0xff)))\\$(printf '%03o' $(((_dino>>24)&0xff)))\\000\\000\\000\\000"
        printf '\000'                        # variant NUL separator (byte 48)
        printf '(tt)'                        # variant type string, not NUL-term (bytes 49-52)
        printf '\032'                        # {sv} framing: end-of-key = 26 = 0x1a (byte 53)
        printf '\066'                        # a{sv} framing: end-of-entry[0] = 54 = 0x36 (byte 54)
    } > /run/ostree-booted
    log "ostree-booted: dev=$_ddev ino=$_dino"
fi

# Avoid "cannot move a shared mount" failures below (same reason real
# ostree-prepare-root does this: Documentation/filesystems/sharedsubtree.txt).
mount --make-rprivate / 2>/dev/null || true

# Assemble the new root at a staging mountpoint.  Prefer composefs (erofs
# image + overlay) when the deployment was checked out with enabled=yes;
# that skips the per-file hardlink step that makes `:: Deploying` slow.
# Fall back to a plain bind-mount if the .cfs file is absent or if any
# kernel primitive (erofs, loop, overlay data-only lower) is unavailable.
DEPLOY_CFS="${DEPLOY}/.ostree.cfs"
COMPOSEFS_MOUNTED=0
if [ -f "$DEPLOY_CFS" ]; then
    modprobe loop    2>/dev/null || true
    modprobe erofs   2>/dev/null || true
    modprobe overlay 2>/dev/null || true
    if grep -q erofs /proc/filesystems 2>/dev/null; then
        CFS_MNT="/tmp/cfs$$"
        mkdir -p "$STAGING" "$CFS_MNT"
        if mount -t erofs -o loop,ro "$DEPLOY_CFS" "$CFS_MNT" 2>/dev/null; then
            OBJECTS="${SYSROOT}/ostree/repo/objects"
            # Use the deployment's backing/root-transient dirs as overlay upper/work.
            # The real ostree-prepare-root does this so libostree can identify the
            # booted deployment by reading the upperdir inode from /proc/mounts.
            DEPLOY_BASENAME="${DEPLOY##*/}"
            BACKING="${SYSROOT}/ostree/deploy/${OSNAME}/backing/${DEPLOY_BASENAME}"
            RT_UPPER="${BACKING}/root-transient/upper"
            RT_WORK="${BACKING}/root-transient/work"
            mkdir -p "$RT_UPPER" "$RT_WORK"
            if mount -t overlay overlay \
               -o "lowerdir=${CFS_MNT}::${OBJECTS},upperdir=${RT_UPPER},workdir=${RT_WORK},redirect_dir=on,metacopy=on" \
               "$STAGING" 2>/dev/null; then
                log "composefs mounted"
                COMPOSEFS_MOUNTED=1
            else
                log "composefs overlay failed, using bind-mount"
                umount "$CFS_MNT" 2>/dev/null || true
                rmdir  "$CFS_MNT" 2>/dev/null || true
            fi
        else
            log "erofs mount failed, using bind-mount"
            rmdir "$CFS_MNT" 2>/dev/null || true
        fi
    else
        log "erofs unavailable, using bind-mount"
    fi
fi
if [ "$COMPOSEFS_MOUNTED" -eq 0 ]; then
    mkdir -p "$STAGING"
    if ! mount --bind "$DEPLOY" "$STAGING"; then
        err "deployment bind-mount FAILED"
        exit 1
    fi
    log "bind-mounted deployment"
fi

# /etc: when composefs is active the erofs lower layer is read-only, so set up
# a writable overlay with the stateroot etc/ as upperdir — same approach as the
# real ostree-prepare-root binary.  For the bind-mount fallback, bind-mount /etc
# onto itself so it gets its own independent mount, immune to the read-only
# remount applied to /usr below.
ETC_STATEROOT="${SYSROOT}/ostree/deploy/${OSNAME}/etc"
if [ "$COMPOSEFS_MOUNTED" -eq 1 ]; then
    # Use the physical deployment /etc as overlay lowerdir. The composefs erofs
    # image covers only the ostree-tracked /usr tree, not /etc; the physical
    # deployment directory always has the full /etc hardlinked from the object
    # store. This path is on the underlying btrfs and is not inside STAGING, so
    # it is unaffected by mount --move.
    ETC_WORK="${SYSROOT}/ostree/deploy/${OSNAME}/.etc-work"
    mkdir -p "$ETC_STATEROOT" "$ETC_WORK"
    if mount -t overlay overlay \
       -o "lowerdir=${DEPLOY}/etc,upperdir=${ETC_STATEROOT},workdir=${ETC_WORK}" \
       "${STAGING}/etc" 2>/dev/null; then
        log "etc overlay mounted (writable)"
    else
        err "etc overlay failed (continuing)"
    fi
else
    if mount --bind "$STAGING/etc" "$STAGING/etc" \
        && mount -o remount,bind "$STAGING/etc"; then
        log "etc is independently writable"
    else
        err "etc bind-mount failed (continuing)"
    fi
fi

# /root: in composefs mode the erofs is baked before bootc install writes
# authorized_keys into the physical deployment /root, so the key is invisible
# through composefs at runtime. An overlay with lowerdir=physical deployment
# /root (has the key) and upperdir=stateroot var/roothome makes it visible and
# keeps /root writable and persistent across upgrades.
if [ "$COMPOSEFS_MOUNTED" -eq 1 ]; then
    ROOT_STATEROOT="${SYSROOT}/ostree/deploy/${OSNAME}/var/roothome"
    ROOT_WORK="${SYSROOT}/ostree/deploy/${OSNAME}/.root-work"
    mkdir -p "$ROOT_STATEROOT" "$ROOT_WORK"
    if mount -t overlay overlay \
       -o "lowerdir=${DEPLOY}/root,upperdir=${ROOT_STATEROOT},workdir=${ROOT_WORK}" \
       "${STAGING}/root" 2>/dev/null; then
        log "root overlay mounted (writable)"
    else
        err "root overlay failed (continuing)"
    fi
fi

# /usr: the actual read-only protection, Fedora/CoreOS-style. Ubuntu is
# usr-merged, so /bin, /sbin, /lib, /lib64 are symlinks into /usr — locking
# down this one directory covers effectively the whole OS payload.
if mount --bind "$STAGING/usr" "$STAGING/usr" \
    && mount -o remount,bind,ro "$STAGING/usr"; then
    log "usr is read-only"
else
    err "usr readonly remount failed (continuing)"
fi

# /var: bind-mount the persistent stateroot directory. This has to happen
# before the move below, while $SYSROOT (not yet replaced) still gives us a
# path to $VAR_SRC.
mkdir -p "$STAGING/var"
if [ -d "$VAR_SRC" ]; then
    if mount --bind "$VAR_SRC" "$STAGING/var"; then
        log "var mounted"
    else
        err "var bind-mount failed (continuing)"
    fi
else
    err "var source $VAR_SRC missing (continuing)"
fi

# /ostree: libostree opens ostree/lock and ostree/repo relative to the sysroot
# root fd (/), not relative to /sysroot. Bind-mount the physical root's ostree/
# directory into the deployment so that /ostree/ is accessible after switch_root.
if [ -d "${SYSROOT}/ostree" ]; then
    mkdir -p "$STAGING/ostree"
    if mount --bind "${SYSROOT}/ostree" "$STAGING/ostree"; then
        log "ostree bind-mounted"
    else
        err "ostree bind-mount failed (continuing)"
    fi
fi

# Move the fully-assembled staging tree onto /sysroot in one atomic step.
# This replaces $SYSROOT (and everything reachable through it) with the
# deployment, carrying the etc/usr/var submounts set up above along with it.
if mount --move "$STAGING" "$SYSROOT"; then
    log "deployment activated"
else
    err "deployment move FAILED"
    exit 1
fi
rmdir "$STAGING" 2>/dev/null

log "done"
exit 0
