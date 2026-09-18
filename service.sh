#!/system/bin/sh
# ==============================================================================
# late_start service : safety net.
# module version: v2.7.2
#
# Some ColorOS builds remount /odm after post-fs-data, which silently drops the
# bind mount.  Wait for boot_completed + audioserver, then verify once and
# re-apply only if the patch really is gone.
# ==============================================================================
MODDIR="${0%/*}"
HIFI="$MODDIR/bin/hifi"
STATE=/data/adb/op13_hifi
LOG="$STATE/last.log"
MARKER="OP13_HIFI_SRC_BYPASS"

(
  i=0
  while [ "$i" -lt 120 ] && [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 1
    i=$((i + 1))
  done
  [ "$(getprop sys.boot_completed)" = "1" ] || exit 0

  i=0
  while [ "$i" -lt 60 ] && [ "$(getprop init.svc.audioserver)" != "running" ]; do
    sleep 1
    i=$((i + 1))
  done

  [ -r "$STATE/config.conf" ] || exit 0
  grep -q '^ENABLED=1$' "$STATE/config.conf" || exit 0

  target=""
  for f in /odm/etc/audio/audio_module_config_primary.xml \
           /vendor/etc/audio/audio_module_config_primary.xml; do
    [ -e "$f" ] && { target="$f"; break; }
  done
  [ -n "$target" ] || exit 0

  # already patched -> nothing to do
  if grep -q "$MARKER" "$target" 2>/dev/null; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: patch present on $target" >> "$LOG"
    exit 0
  fi

  echo "$(date '+%Y-%m-%d %H:%M:%S') boot verify: patch missing, re-applying" >> "$LOG"
  # a remount means the mount was dropped for real, so no audio restart is needed
  /system/bin/sh "$HIFI" set restart 0 >> "$LOG" 2>&1
  /system/bin/sh "$HIFI" apply >> "$LOG" 2>&1
  /system/bin/sh "$HIFI" set restart 1 >> "$LOG" 2>&1
) &
