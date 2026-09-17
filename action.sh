#!/system/bin/sh
# ==============================================================================
# Action button (Magisk / KernelSU / APatch)
# module version: v2.6
#
#   not applied  ->  apply the patch
#   applied      ->  ONE-TAP RESTORE, back to the factory audio policy
#
# The restore path is lossless and reversible: it only unmounts the bind and
# sets ENABLED=0.  Your mixer / ceiling settings are kept, so tapping the button
# again re-applies exactly the same configuration.
# ==============================================================================
MODDIR="${0%/*}"
HIFI="$MODDIR/bin/hifi"

echo "=============================================="
echo " OP13 HiFi - USB SRC Bypass"
echo "=============================================="
/system/bin/sh "$HIFI" status
echo ""

target=""
for f in /odm/etc/audio/audio_module_config_primary.xml \
         /vendor/etc/audio/audio_module_config_primary.xml; do
  [ -e "$f" ] && { target="$f"; break; }
done

if [ -n "$target" ] && grep -q 'OP13_HIFI_SRC_BYPASS' "$target" 2>/dev/null; then
  echo "--> the patch is ACTIVE, restoring the factory policy ..."
  echo ""
  /system/bin/sh "$HIFI" restore
else
  echo "--> the factory policy is in use, applying the patch ..."
  echo ""
  /system/bin/sh "$HIFI" set enabled 1 >/dev/null 2>&1
  /system/bin/sh "$HIFI" apply
fi

echo ""
echo "=============================================="
echo " done -- tap the button again to toggle"
echo " fine control: hifi preset 384k | 192k | 44k"
echo "=============================================="
