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
    modprobe loop  2>/dev/null || true
    modprobe erofs 2>/dev/null || true
    if grep -q erofs /proc/filesystems 2>/dev/null; then
        CFS_MNT="/tmp/cfs$$"
        mkdir -p "$STAGING" "$CFS_MNT"
        if mount -t erofs -o loop,ro "$DEPLOY_CFS" "$CFS_MNT" 2>/dev/null; then
            OBJECTS="${SYSROOT}/ostree/repo/objects"
            if mount -t overlay overlay \
               -o "lowerdir=${CFS_MNT}::${OBJECTS},redirect_dir=on,metacopy=on" \
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

# /etc: same technique real ostree-prepare-root uses — bind-mount it onto
# itself so it becomes its own independent mount, immune to the read-only
# remount applied to /usr below.
if mount --bind "$STAGING/etc" "$STAGING/etc" \
    && mount -o remount,bind "$STAGING/etc"; then
    log "etc is independently writable"
else
    err "etc bind-mount failed (continuing)"
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
