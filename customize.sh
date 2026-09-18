#!/system/bin/sh
# ==============================================================================
# OP13 HiFi - USB SRC Bypass   v2.7.1   installer
# ------------------------------------------------------------------------------
# Runs under Magisk / KernelSU / APatch.
# On an *update* the user settings in /data/adb/op13_hifi/config.conf are kept.
# ==============================================================================

ui_print "***************************************************"
ui_print "  OP13 HiFi - USB SRC Bypass   v2.7.1"
ui_print "  OnePlus 13 . ColorOS 16 . QTI AIDL audio"
ui_print "***************************************************"

# ---------------------------------------------------------------- device check
DEV="$(getprop ro.product.device)"
MODEL="$(getprop ro.product.model)"
SDK="$(getprop ro.build.version.sdk)"
OPLUS_VER="$(getprop ro.build.version.oplusrom 2>/dev/null)"

ui_print "- device       : $DEV / $MODEL (SDK $SDK)"
[ -n "$OPLUS_VER" ] && ui_print "- ColorOS rom  : $OPLUS_VER"

case "$DEV" in
  OP5D0DL1|OP5D1L1|OP5D2L1|OP5D3L1|CPH2649|PJZ110|*13*|*13T*)
    ui_print "- device family: recognised" ;;
  *)
    ui_print "! this module was built for the OnePlus 13 (ColorOS 16)."
    ui_print "! It installs anyway, but only touch it if you know your ROM uses"
    ui_print "! /odm/etc/audio/audio_module_config_primary.xml (Qualcomm AIDL)." ;;
esac

# --------------------------------------------------------------- target locate
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

if [ -n "$TARGET" ]; then
  ui_print "- audio policy : $TARGET"
else
  ui_print "! audio_module_config_primary.xml was NOT found."
  ui_print "! This module targets Qualcomm AIDL audio (ColorOS 16)."
  ui_print "! It installs but stays inert on other platforms."
fi

# ------------------------------------------------------------- state dir init
STATE=/data/adb/op13_hifi
mkdir -p "$STATE/stock" "$STATE/patched" 2>/dev/null
chmod 0755 "$STATE" "$STATE/stock" "$STATE/patched" 2>/dev/null

if [ -e "$STATE/.stock_saved" ]; then
  ui_print "- factory backup already present, keeping it"
fi

UPDATE=0
if [ -r "$STATE/config.conf" ]; then
  UPDATE=1
  ui_print "- existing settings kept (update in place)"
else
  cat > "$STATE/config.conf" <<EOF
MIXER_RATE=48000
MAX_RATE=384000
ENABLED=1
RESTART=1
EOF
  chmod 0644 "$STATE/config.conf" 2>/dev/null
  ui_print "- defaults written: mixer 48000 Hz / direct ceiling 384000 Hz"
fi

# ------------------------------------------------------------------- permissions
if command -v set_perm >/dev/null 2>&1; then
  set_perm "$MODPATH/bin/hifi"        0 0 0755
  set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
  set_perm "$MODPATH/service.sh"      0 0 0755
  set_perm "$MODPATH/action.sh"       0 0 0755
  set_perm "$MODPATH/uninstall.sh"    0 0 0755
  set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
  set_perm_recursive "$MODPATH/payload" 0 0 0755 0644
else
  chmod 0755 "$MODPATH/bin/hifi" "$MODPATH/post-fs-data.sh" \
             "$MODPATH/service.sh" "$MODPATH/action.sh" \
             "$MODPATH/uninstall.sh" 2>/dev/null
  chmod 0644 "$MODPATH/payload/"*.tmpl "$MODPATH/webroot/"* 2>/dev/null
fi

# --------------------------------------------------------------- sanity output
ui_print ""
ui_print "- presets     : 384k | 192k | 96k | 44k (44.1k library)"
ui_print "- one-tap restore : module action button, or the WebUI button,"
ui_print "                    or: sh /data/adb/modules/op13_hifi_src_bypass/bin/hifi restore"
if [ "$UPDATE" = 1 ]; then
  ui_print "- reboot to activate the updated build"
else
  ui_print "- reboot to activate"
  ui_print "- KernelSU / APatch: open this module page -> WebUI"
  ui_print "- Magisk: use the action button, or a terminal"
fi
