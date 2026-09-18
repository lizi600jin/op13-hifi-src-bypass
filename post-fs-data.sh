#!/system/bin/sh
# ==============================================================================
# post-fs-data : mount the patched audio policy before audioserver starts.
# module version: v2.7.1
#
# This stage runs in the module manager's own mount namespace, so bin/hifi
# re-execs itself through `nsenter -t 1 -m` to reach the global namespace.
# The factory file itself is never written to -- a bind mount is used instead.
# ==============================================================================
MODDIR="${0%/*}"
[ -x "$MODDIR/bin/hifi" ] || chmod 0755 "$MODDIR/bin/hifi" 2>/dev/null
/system/bin/sh "$MODDIR/bin/hifi" boot >/dev/null 2>&1
exit 0
