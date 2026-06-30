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

# Mount var at /sysroot/var BEFORE the deployment bind-mount shadows
# the ostree directory tree. The mount persists after /sysroot is replaced.
mkdir -p "${SYSROOT}/var"
if [ -d "$VAR_SRC" ]; then
    if mount --bind "$VAR_SRC" "${SYSROOT}/var"; then
        log "var mounted"
    else
        err "var bind-mount failed (continuing)"
    fi
fi

# Activate the deployment: bind-mount it over /sysroot.
if mount --bind "$DEPLOY" "$SYSROOT"; then
    log "deployment activated"
else
    err "deployment bind-mount FAILED"
    exit 1
fi

log "done"
exit 0
