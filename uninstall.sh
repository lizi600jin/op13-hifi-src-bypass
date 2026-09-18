#!/system/bin/sh
# ==============================================================================
# OP13 HiFi - USB SRC Bypass   v2.7.2   uninstall.sh
#
# Executed by Magisk / KernelSU / APatch right before the module directory is
# deleted.  Goal: leave the device byte-identical to a stock one.
#
#   1. remove the bind mount from every mount namespace we can reach
#   2. put the factory file back if it was ever overwritten
#   3. delete /data/adb/op13_hifi  (patched file, archive, settings, logs)
#   4. delete stray temp files
#   5. never touch /odm itself -- the module never wrote to it
#
# Deliberately self-contained: it still works if bin/hifi is already gone.
# ==============================================================================

set -u

MODDIR="${MODDIR:-${0%/*}}"
STATE=/data/adb/op13_hifi
CONF="$STATE/config.conf"
STOCK="$STATE/stock/audio_module_config_primary.xml"
MARKER="OP13_HIFI_SRC_BYPASS"
LOGTAG="op13_hifi_uninstall"

say() { printf '%s: %s\n' "$LOGTAG" "$*"; }

say "=== OP13 HiFi uninstall: removing every trace ==="

# ------------------------------------------------------------------ 1. target
TARGET=""
for f in \
  /odm/etc/audio/audio_module_config_primary.xml \
  /vendor/etc/audio/audio_module_config_primary.xml \
  /system/vendor/etc/audio/audio_module_config_primary.xml \
  /system/etc/audio/audio_module_config_primary.xml
do
  [ -e "$f" ] && { TARGET="$f"; break; }
done
if [ -z "$TARGET" ]; then
  for root in /odm /vendor /system/vendor /system; do
    [ -d "$root" ] || continue
    hit="$(find "$root" -maxdepth 5 -name audio_module_config_primary.xml 2>/dev/null | head -n1)"
    [ -n "$hit" ] && { TARGET="$hit"; break; }
  done
fi

is_mounted() {
  awk -v t="$1" '$2 == t { found = 1 } END { exit !found }' /proc/mounts 2>/dev/null
}

is_ours() {
  [ -r "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null
}

# -------------------------------------------------------------- 2. unmount
if [ -n "$TARGET" ]; then
  say "target file: $TARGET"

  # 2a. the global (init) namespace is the one audioserver actually reads
  nsenter -t 1 -m -- umount "$TARGET" 2>/dev/null
  is_mounted "$TARGET" && umount "$TARGET" 2>/dev/null
  is_mounted "$TARGET" && umount -l "$TARGET" 2>/dev/null

  # 2b. sweep the remaining namespaces (managers often stay isolated)
  for d in /proc/[0-9]*; do
    [ -r "$d/mounts" ] || continue
    if awk -v t="$TARGET" '$2 == t { found = 1 } END { exit !found }' "$d/mounts" 2>/dev/null; then
      pid="${d#/proc/}"
      nsenter -t "$pid" -m -- umount "$TARGET" 2>/dev/null
      nsenter -t "$pid" -m -- umount -l "$TARGET" 2>/dev/null
    fi
  done

  if is_mounted "$TARGET"; then
    say "WARNING: $TARGET is still mounted -- one reboot completes the removal"
  else
    say "bind mount removed"
  fi

  # 2c. last resort: if the real file was overwritten, put the archive back
  if is_ours "$TARGET"; then
    if [ -r "$STOCK" ]; then
      say "the on-disk file carries our patch, writing the factory archive back"
      if cp -f "$STOCK" "$TARGET" 2>/dev/null; then
        chmod 0644 "$TARGET" 2>/dev/null
        chown 0:0 "$TARGET" 2>/dev/null
        say "factory file restored from $STOCK"
      else
        say "WARNING: could not write the factory file back -- one reboot recovers"
      fi
    else
      say "WARNING: patched file in place and no archive available -- reboot recovers"
    fi
  fi
else
  say "no audio_module_config_primary.xml found (nothing to unmount)"
fi

# --------------------------------------------- 3. keep the settings in the log
if [ -r "$CONF" ]; then
  say "-- settings being removed (keep them if you reinstall) --"
  sed 's/^/    /' "$CONF" 2>/dev/null
  say "-- end of settings --"
fi

# ------------------------------------------------- 4. wipe the state directory
if [ -d "$STATE" ]; then
  rm -rf "$STATE" 2>/dev/null
  if [ -d "$STATE" ]; then
    say "WARNING: $STATE could not be removed"
  else
    say "state directory removed: $STATE"
  fi
else
  say "state directory already absent: $STATE"
fi

# ------------------------------------------------------- 5. stray temp files
rm -rf /data/local/tmp/op13_hifi* 2>/dev/null
rm -f  /data/local/tmp/hifi* 2>/dev/null
rm -f  /data/local/tmp/probe192.sh 2>/dev/null
rm -rf /data/adb/modules_update/op13_hifi_src_bypass 2>/dev/null

# ------------------------------------------------------- 6. final assertion
if [ -n "$TARGET" ]; then
  if is_mounted "$TARGET"; then
    say "RESULT: mount still present -- one reboot completes the cleanup"
  elif is_ours "$TARGET"; then
    say "RESULT: file still patched -- one reboot completes the cleanup"
  else
    say "RESULT: CLEAN -- factory file in use, no residue left"
  fi
  say "/odm was never written to by this module"
fi

say "=== OP13 HiFi uninstall finished ==="
exit 0
