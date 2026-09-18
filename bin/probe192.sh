#!/system/bin/sh
# ==============================================================================
# OP13 HiFi - HiFi 直通生效验证器（采样率 + 位深）   probe192.sh   v2.7.1
#
#   用法 A（模块已装）:
#     su -c "sh /data/adb/modules/op13_hifi_src_bypass/bin/probe192.sh"
#     su -c "/data/adb/modules/op13_hifi_src_bypass/bin/hifi doctor"
#
#   用法 B（还没刷模块，adb 推上去）:
#     adb push probe192.sh /data/local/tmp/
#     adb shell su -c "sh /data/local/tmp/probe192.sh"
#
#   九段输出，最后给结论。核心判据（很多人看错的就是这一条）：
#
#     * stream0 里的 Rates          = DAC【对外声明】支持什么 → 只证明"支持"
#     * hw_params 里的 rate/format  = 此刻【真正协商出来】的频率/位深 → 这是证据
#     * hw_params 的 owner_pid      = 谁在放
#          audioserver        → 走 Android 音频栈，本模块的策略在链路上
#          第三方 App 占裸 USB → App 自带 USB 驱动，本模块对它完全无关
#
#   v2.1 判定层升级（针对"第 5 段永远是 closed"的报告）：
#     * 第 5 段改为【三态判定】D1/D2/D3 ——
#         D1 找到 0 个 pcm 目录 → 本机内核没导出 pcm 子目录，/proc 这条观察通道
#            在这台机器上天然不可用（不是模块没生效，改多少版检测脚本都一样），
#            D 层以 5b 为准；
#         D2 有 pcm 目录但全部 closed → 检测时暂停了，或音频被播放器自带 USB
#            驱动（独占）接管，根本没经过 ALSA；
#         D3 有打开的 PCM 流 → 打印明细与归属。
#     * 5b 段升级：把 uid 解析成包名，直接点名"是谁在放"。
#     * 新增 5c 段：对网易云音乐 / QQ音乐 / 海贝音乐 逐个判定它当前走的是
#       直通（模块在链路上）还是混音路径（位深由 App 自己的请求决定），
#       还是没走 Android 音频栈（自带驱动独占）。
#     * 第 7 段结论改为机器判定 + 三 App 指引，不再只说"这一步还判不了"。
# ==============================================================================

set -u

# 离线自测时可指向一棵伪造的 asound 树（Windows 上必须用正斜杠）
CARD_ROOT="${OP13_FAKE_ASOUND:-/proc/asound}"
POLICY_TARGETS="/odm/etc/audio/audio_module_config_primary.xml \
/vendor/etc/audio/audio_module_config_primary.xml \
/system/vendor/etc/audio/audio_module_config_primary.xml \
/system/etc/audio/audio_module_config_primary.xml"

hr()  { printf '%s\n' "------------------------------------------------------------"; }
sec() { printf '\n'; hr; printf '[%s] %s\n' "$1" "$2"; hr; }

# ------------------------------------------------------------------- helpers
find_policy() {
  for f in $POLICY_TARGETS; do
    [ -e "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  for root in /odm /vendor /system/vendor /system; do
    [ -d "$root" ] || continue
    h="$(find "$root" -maxdepth 5 -name audio_module_config_primary.xml 2>/dev/null | head -n1)"
    [ -n "$h" ] && { printf '%s\n' "$h"; return 0; }
  done
  return 1
}

# 去掉 XML 注释（含跨行注释）。
# 原厂文件里有 #ifndef OPLUS_* / #else 伪预处理块，**另一个分支是以 <!-- ... --> 注释掉的**，
# 不去掉就会把"没生效"的 profile 和采样率也算进来 —— 典型症状就是
# 「A 段算出来的上限(192000) 比 B 段 audioserver 实际读到的(96000) 还大」。
# 这个坑在本项目里踩过两次（Python 校验器一次、这里一次），统一走 stripc。
stripc() {
  awk 'BEGIN{inc=0}
  {
    line=$0; out=""
    while (line != "") {
      if (inc) {
        i = index(line, "-->")
        if (i == 0) { line = "" }
        else { line = substr(line, i+3); inc = 0 }
      } else {
        i = index(line, "<!--")
        if (i == 0) { out = out line; line = "" }
        else { out = out substr(line, 1, i-1); line = substr(line, i+4); inc = 1 }
      }
    }
    print out
  }'
}

rates_of()   { sed -n 's/.*samplingRates="\([^"]*\)".*/\1/p' | tr ' ' '\n' | grep -E '^[0-9]+$'; }
mix_block()  { sed -n "/<mixPort name=\"$2\"/,/<\/mixPort>/p" "$1" 2>/dev/null | stripc; }
dev_block()  { sed -n "/<devicePort tagName=\"$2\"/,/<\/devicePort>/p" "$1" 2>/dev/null | stripc; }
mix_raw()    { sed -n "/<mixPort name=\"$2\"/,/<\/mixPort>/p" "$1" 2>/dev/null; }
dev_raw()    { sed -n "/<devicePort tagName=\"$2\"/,/<\/devicePort>/p" "$1" 2>/dev/null; }
mix_max()    { mix_block "$1" "$2" | rates_of | sort -n | tail -n1; }
dev_max()    { dev_block "$1" "$2" | rates_of | sort -n | tail -n1; }
mix_has()    { mix_block "$1" "$2" | rates_of | grep -qx "$3" && echo yes || echo no; }
dev_has()    { dev_block "$1" "$2" | rates_of | grep -qx "$3" && echo yes || echo no; }
# 只列真正生效的 pcmType（注释已被 stripc 去掉），按字母序 → INT_16/24/32
# 结尾的 tr 会留一个尾随空格，必须去掉，否则跟期望值做字符串比较会假报"不一致"
live_pcms()  { grep -o 'pcmType="[^"]*"' | sed 's/pcmType="//; s/"//' \
               | sort -u | tr '\n' ' ' | sed 's/ *$//'; }

proc_of() {
  [ -n "${1:-}" ] || return 0
  c=""
  # < /proc/PID/cmdline 打不开时，报错是 shell 发的，2>/dev/null 挡不住，所以先判可读
  [ -r "/proc/$1/cmdline" ] && c="$(tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)"
  [ -n "$c" ] || c="$(cat "/proc/$1/comm" 2>/dev/null)"
  printf '%s' "${c:-unknown}"
}

printf "OP13 HiFi - HiFi 直通生效验证（采样率 + 位深）\n"
printf '时间 : %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
printf '机型 : %s / %s   SDK %s\n' "$(getprop ro.product.device)" \
       "$(getprop ro.product.model)" "$(getprop ro.build.version.sdk)"
printf '内核 : %s\n' "$(uname -r 2>/dev/null)"

# ------------------------------------------------ 期望值（来自模块自己的配置）
# 所有"达没达标"的判断都必须跟这里比，而不是跟某个写死的 192k 比
CONFIG=/data/adb/op13_hifi/config.conf
CONFIG_MIX="$(sed -n 's/^MIXER_RATE=//p'   "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_MAX="$(sed -n 's/^MAX_RATE=//p'     "$CONFIG" 2>/dev/null | head -n1)"
CONFIG_BITS="$(sed -n 's/^BIT_DEPTH=//p'  "$CONFIG" 2>/dev/null | head -n1)"
case "${CONFIG_BITS:-32}" in
  16) WANT_PCMS="INT_16_BIT" ;;
  24) WANT_PCMS="INT_16_BIT INT_24_BIT" ;;
  *)  WANT_PCMS="INT_16_BIT INT_24_BIT INT_32_BIT" ;;
esac
WANT_N=1
[ "${CONFIG_BITS:-32}" -ge 24 ] 2>/dev/null && WANT_N=2
[ "${CONFIG_BITS:-32}" -ge 32 ] 2>/dev/null && WANT_N=3

# ==================================================== 1. 模块与策略文件状态
sec 1 "模块与生效中的策略文件"
APPLIED=no
POLICY="$(find_policy 2>/dev/null)" || POLICY=""
if [ -n "$POLICY" ]; then
  printf '策略文件     : %s\n' "$POLICY"
  if grep -q 'OP13_HIFI_SRC_BYPASS' "$POLICY" 2>/dev/null; then
    APPLIED=yes
    printf '补丁状态     : 已挂载（读到的是本模块生成的文件）\n'
    grep -o 'mixer=[0-9]* direct_max=[0-9]*' "$POLICY" 2>/dev/null | sed 's/^/               /'
  else
    printf '补丁状态     : 未挂载（读到的是原厂文件）\n'
  fi
  if awk -v t="$POLICY" '$2==t{f=1}END{exit !f}' /proc/mounts 2>/dev/null; then
    printf '/proc/mounts : 确认存在绑定挂载\n'
  else
    printf '/proc/mounts : 无绑定挂载记录\n'
  fi
else
  printf '策略文件     : 未找到 audio_module_config_primary.xml\n'
fi
printf 'audioserver  : %s\n' "$(getprop init.svc.audioserver)"
printf '模块目录     : '
for m in /data/adb/modules/op13_hifi_src_bypass /data/adb/modules_update/op13_hifi_src_bypass; do
  [ -d "$m" ] && printf '%s ' "$m"
done
printf '\n'

# ============================================= 2. 各端口上限（证据 A：配置层）
sec 2 "生效文件里的上限（证据 A：配置层）"
if [ -n "$POLICY" ]; then
  printf '配置(config.conf) : 混音 %s Hz / 采样率上限 %s Hz / 位深上限 %s bit\n' \
    "${CONFIG_MIX:-?}" "${CONFIG_MAX:-?}" "${CONFIG_BITS:-?}"
  printf '\n%-26s %-12s %-14s\n' "端口" "最高采样率" "达配置上限?"
  for p in direct_pcm_out low_latency_out deep_buffer_out; do
    printf '%-26s %-12s %-14s\n' "mixPort:$p" "$(mix_max "$POLICY" "$p")" \
      "$(mix_has "$POLICY" "$p" "${CONFIG_MAX:-0}")"
  done
  for p in usb_headset usb_device_out wired_headset wired_headphones; do
    printf '%-26s %-12s %-14s\n' "dev:$p" "$(dev_max "$POLICY" "$p")" \
      "$(dev_has "$POLICY" "$p" "${CONFIG_MAX:-0}")"
  done

  printf '\n小尾巴端口的位深（已去掉注释，只算真正生效的；停用的是显式注释行）：\n'
  for p in usb_headset usb_device_out; do
    printf '  %-16s 生效: %-40s 停用 %s 条\n' "$p" \
      "$(dev_block "$POLICY" "$p" | live_pcms)" \
      "$(dev_raw "$POLICY" "$p" | grep -c 'disabled (BIT_DEPTH' 2>/dev/null)"
  done
  for p in usb_headset usb_device_out; do
    got="$(dev_block "$POLICY" "$p" | live_pcms)"
    if [ "$got" = "$WANT_PCMS" ]; then
      printf '  -> %-14s 与 BIT_DEPTH=%s 一致  OK\n' "$p" "${CONFIG_BITS:-32}"
    else
      printf '  -> %-14s 与 BIT_DEPTH=%s 不一致！期望 [%s] 实际 [%s]\n' \
        "$p" "${CONFIG_BITS:-32}" "$WANT_PCMS" "$got"
    fi
  done
else
  printf '跳过\n'
fi

# ============================== 3. audioserver 视角（证据 B：系统是否真读到）
sec 3 "系统侧看到的 direct_pcm_out（证据 B：audioserver 是否读到了补丁）"
# 注意：**不能**把 dumpsys 的输出塞进变量再用 printf 输出。
# `printf '%s\n' "$DUMP"` 会把整份 dump 当成一个 argv 参数，Linux 单个参数上限 128KB
# （MAX_ARG_STRLEN），audio_policy 的 dump 很容易超过 —— 于是 4 处 printf 全部
# 报 "Argument list too long"，而错误只走 stderr、又被 2>/dev/null 吞掉，
# 表现为"Config source 空白、上限未取到、USB 端口列表空白"，看起来像权限问题，其实不是。
DUMPF=/data/local/tmp/.op13_probe_dump.txt
dumpsys media.audio_policy > "$DUMPF" 2>/dev/null
if [ ! -s "$DUMPF" ]; then
  printf 'dumpsys 无输出（或者被 SELinux 拦了）\n'
else
  printf 'dump 大小 : %s 行（写入 %s 做分析，脚本结束会删掉）\n' \
    "$(wc -l < "$DUMPF" 2>/dev/null)" "$DUMPF"
  printf 'Config source : %s\n' "$(cat "$DUMPF" | sed -n 's/^ *Config source: *//p' | head -n1)"
  dmax="$(cat "$DUMPF" \
    | awk '/"direct_pcm_out"/{f=1} f && /";[[:space:]]*0x/ && !/direct_pcm_out/{exit} f' \
    | sed -n 's/.*sampling rates: *//p' | tr ',' '\n' | tr -d ' ' | grep -E '^[0-9]+$' | sort -n | tail -n1)"
  printf 'direct_pcm_out 运行时上限 : %s\n' "${dmax:-未取到}"
  # 判决必须跟"配置里写的上限"比。以前这里写死了 192k，用户选 96k 时会误报"补丁没有生效"。
  if [ -n "$dmax" ]; then
    if [ -n "${CONFIG_MAX:-}" ] && [ "$dmax" -eq "$CONFIG_MAX" ] 2>/dev/null; then
      printf '  -> 与配置的 %s Hz 一致：audioserver 已读到补丁，B 层生效\n' "$CONFIG_MAX"
    else
      # 单看 dmax 说明不了问题：可能只是"配置的上限本来就在这个值以下"
      hi="$(mix_max "$POLICY" "direct_pcm_out")"
      if [ -n "$hi" ] && [ "$dmax" -eq "$hi" ] 2>/dev/null; then
        printf '  -> 与生效文件里的 direct_pcm_out 上限(%s)一致，但它和配置的 %s Hz 不同\n' \
               "$hi" "${CONFIG_MAX:-未知}"
      else
        printf '  -> dmax=%s 与配置的 %s Hz 不符 —— 可能没生效，或被 ROM 重挂顶掉了\n' \
               "$dmax" "${CONFIG_MAX:-未知}"
      fi
    fi
  fi

  printf '\nUSB 输出端口的运行时能力（位深真正生效的地方 —— 原厂这里只有 PCM_16_BIT）：\n'
  cat "$DUMPF" | awk '
    /Port ID: *[0-9]+; "(usb_headset|usb_device_out)"/ { u=1; print "  ==== " $0; next }
    u && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ { u=0 }
    u && /AUDIO_FORMAT_/    { print "      " $0 }
    u && /sampling rates:/  { print "        " $0 }
  ' | head -n 24

  printf '\n"可用输出设备"里的 USB 声卡（有它才说明小尾巴被系统认到）：\n'
  cat "$DUMPF" | awk '
    /Available output devices/ { av=1 }
    av && /Available input devices/ { av=0 }
    av && /"(usb_headset|usb_device_out)";/ { u=1; print "  ---- 找到 USB 输出 ----"; print "  "$0; next }
    av && u && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ { u=0 }
    av && u { print "  "$0 }
  '
fi
D_DUMP_OK=no; [ -s "$DUMPF" ] && D_DUMP_OK=yes
rm -f "$DUMPF" 2>/dev/null

# =============================== 4. DAC 声明能力（证据 C：只是"支持"什么）
sec 4 "USB 声卡的声明能力（证据 C：DAC 声明支持什么 —— 不是此刻在跑什么）"
FOUND_USB_CARD=""
if [ ! -d "$CARD_ROOT" ]; then
  printf '! %s 不存在（内核未开 SND_PROC_FS），无法读取\n' "$CARD_ROOT"
else
  if [ -r "$CARD_ROOT/cards" ]; then
    printf '%s\n' "--- /proc/asound/cards ---"
    sed 's/^/  /' "$CARD_ROOT/cards"
  fi
  for c in "$CARD_ROOT"/card[0-9]*; do
    [ -d "$c" ] || continue
    n="${c##*card}"
    st="$c/stream0"
    [ -r "$st" ] || continue
    head1="$(head -n1 "$st")"
    case "$head1" in
      *' at usb-'*) kind="USB" ;;
      *)            kind="内置/其它" ;;
    esac
    printf '\n  card%s  [%s]  %s\n' "$n" "$kind" "$head1"
    if [ "$kind" = "USB" ]; then
      FOUND_USB_CARD="$n"
      pb="$(sed -n '/Playback:/,/Capture:/p' "$st" 2>/dev/null)"
      printf '    Playback Status : %s\n' "$(printf '%s\n' "$pb" | sed -n 's/^ *Status: *//p' | head -n1)"
      printf '%s\n' "$pb" | awk '
        /Altset/  { a=$0; sub(/^[ \t]+/,"",a) }
        /Format:/ { f=$0; sub(/^[ \t]+/,"",f) }
        /Rates:/  { r=$0; sub(/^[ \t]+/,"",r); printf "    %-10s %-16s %s\n", a, f, r }
      '
      printf '    ↑ 这些 Rates 只是 DAC 声明的能力上限，不代表此刻在跑\n'
    fi
  done
fi
if [ -z "$FOUND_USB_CARD" ]; then
  printf '\n! %s 里没有 USB 音频声卡。可能原因（按可能性排序）：\n' "$CARD_ROOT"
  printf '  1) **小尾巴被某个 App 用自带 USB 驱动抢走了**（"独占"的另一种实现）。\n'
  printf '     这种情况下内核 snd-usb-audio 不会绑定该 USB 设备、也就不会建 ALSA 声卡，\n'
  printf '     但 dumpsys 里仍可能残留它的描述符 —— 下面第 4b 段的绑定情况可以判定。\n'
  printf '  2) USB-C 接触不良 / 没插到底 / 转接头不合规，设备没枚举成功。\n'
  printf '  3) 该耳机是【模拟】Type-C（吃手机自带 codec，走 wired_headset），本来就不会出现在这里。\n'
fi

# -------------------------------- 4b. 内核侧：USB 音频接口到底归谁
# 判据的核心是【接口级】driver（/sys/bus/usb/drivers/<drv>/<bus-iface>），
# 不是设备级 driver（设备级永远是 usb，没有信息量）。
# 另外：数"绑定了几个"绝不能 `ls -l ... | grep -c ' -> '` —— 那会把 `module`
# 这个符号链接也算进去，于是永远 >=1，正是这个 bug 让人误判"驱动绑定正常"。
printf '\n--- 4b. 内核侧：USB 音频接口归谁 ---\n'
printf '  snd-usb-audio = 内核 ALSA 接管（正常，声音走 Android 音频栈）\n'
printf '  usbfs         = 被某个进程独占直连（App 自带 USB 驱动，绕过整个音频栈）\n'
printf '  （无 driver）  = 没有驱动，谁都放不出声，拔插一次即可恢复\n\n'
USB_USBFS=""
for drv in /sys/bus/usb/drivers/*; do
  dn="$(basename "$drv")"
  ifaces="$(ls "$drv" 2>/dev/null | grep ':' | tr '\n' ' ')"
  ifaces="$(printf '%s' "$ifaces" | sed 's/ *$//')"
  n="$(printf '%s' "$ifaces" | wc -w)"     # 按“字段数”数，别用 grep -c（整行只算 1 行）
  [ "${n:-0}" -gt 0 ] 2>/dev/null || continue
  printf '  %-14s 绑定 %s 个接口: %s\n' "$dn" "$n" "$ifaces"
  [ "$dn" = "usbfs" ] && USB_USBFS="$ifaces"
done
SND_N="$(ls /sys/bus/usb/drivers/snd-usb-audio/ 2>/dev/null | grep -c ':')"
USBFS_N="$(ls /sys/bus/usb/drivers/usbfs/ 2>/dev/null | grep -c ':')"
printf '\n  snd-usb-audio 绑定接口数 : %s\n' "${SND_N:-0}"
printf '  usbfs         绑定接口数 : %s\n' "${USBFS_N:-0}"
printf '  ALSA 声卡（/sys/class/sound 的 card*）: %s 张\n' \
  "$(ls /sys/class/sound/ 2>/dev/null | grep -c '^card')"
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '  >>> 结论：小尾巴的音频接口被 usbfs 接管了 —— 音频【绕开了 Android 音频栈】，\n'
  printf '      本模块（改的是 audio_policy 配置）在这条路径上完全不起作用。\n'
  printf '      关掉播放器的"独占 USB"，然后【拔插一次】小尾巴，让内核把驱动抢回来。\n'
elif [ "${SND_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '  >>> 结论：内核 ALSA 已接管，声音走 Android 音频栈，本模块在链路上。\n'
else
  printf '  >>> 结论：音频接口当前【没有驱动】—— 通常是刚被"独占"释放过。\n'
  printf '      拔插一次小尾巴即可让 snd-usb-audio 重新绑定。\n'
fi

# ============================ 5. 真正协商出来的频率（证据 D：决定性证据）
sec 5 "此刻真正协商出来的频率与位深（证据 D：决定性）"
printf '请在【正在播放 24bit/192kHz 音乐】的时候看这一段。\n\n'
ANY_OPEN=no
PCM_DIRS=0
PCM_OPEN_N=0
for pcm in "$CARD_ROOT"/card[0-9]*/pcm*c "$CARD_ROOT"/card[0-9]*/pcm*p; do
  [ -d "$pcm" ] || continue
  PCM_DIRS=$((PCM_DIRS + 1))
  for sub in "$pcm"/sub*; do
    [ -d "$sub" ] || continue
    hp="$(cat "$sub/hw_params" 2>/dev/null)"
    stt="$(cat "$sub/status" 2>/dev/null)"
    case "$hp" in
      *closed*) continue ;;
      "") continue ;;
    esac
    ANY_OPEN=yes
    PCM_OPEN_N=$((PCM_OPEN_N + 1))
    printf '  ● /proc/asound/%s  ——  正在使用\n' "${pcm#$CARD_ROOT/}"
    printf '%s\n' "$hp" | sed -n 's/^ *\(access\|format\|subformat\|channels\|rate\) *: *\(.*\)/      \1 : \2/p'
    opid="$(printf '%s\n' "$stt" | sed -n 's/^ *owner_pid *: *//p' | head -n1)"
    printf '      state       : %s\n' "$(printf '%s\n' "$stt" | sed -n 's/^ *state: *//p' | head -n1)"
    printf '      owner_pid   : %s  (%s)\n' "${opid:-?}" "$(proc_of "${opid:-}")"
    rate="$(printf '%s\n' "$hp" | sed -n 's/^ *rate: *\([0-9]*\).*/\1/p' | head -n1)"
    case "$rate" in
      "")            : ;;
      192000)        printf '      >>> 协商成功：192000 Hz\n' ;;
      352800|384000) printf '      >>> 协商成功：%s Hz\n' "$rate" ;;
      176400)        printf '      >>> %s Hz（176.4k；若音源就是 176.4k 则正常）\n' "$rate" ;;
      *)             printf '      >>> 当前 %s Hz\n' "$rate" ;;
    esac
    # --- 位深：这才是大多数小尾巴的真瓶颈 -------------------------------
    fmtv="$(printf '%s\n' "$hp" | sed -n 's/^ *format *: *//p' | head -n1)"
    sbits="$(printf '%s' "$fmtv" | sed -n 's/^S\([0-9]*\)_.*/\1/p')"
    if [ -n "$sbits" ]; then
      want_b="${CONFIG_BITS:-32}"
      printf '      >>> 真正协商出的位深：%s  (%s bit)\n' "$fmtv" "$sbits"
      if [ "$sbits" -ge "$want_b" ] 2>/dev/null; then
        printf '      >>> 已达到配置的 %sbit 位深上限：模块的位深档位生效\n' "$want_b"
      else
        printf '      >>> 只有 %sbit，低于配置的 %sbit 上限\n' "$sbits" "$want_b"
        printf '          （可能是音源位深本来更低、App 没申请高解析、或补丁/24bit 档没生效）\n'
      fi
    fi
    case "$(proc_of "${opid:-}")" in
      *audioserver*) NOTE_MODE="android" ;;
      *) [ -n "${opid:-}" ] && NOTE_MODE="app" ;;
    esac
    NOTE_RUN=yes
    printf '\n'
  done
done

# --- 三态判定（v2.1）：不再笼统说 closed，而是分清"检测不到"和"真的没在放" ---
if [ "$PCM_DIRS" = 0 ]; then
  D_VERDICT="D1"
  if [ "${D_DUMP_OK:-}" = yes ]; then
    printf '  【D1】/proc/asound 观察通道本机不可用（0 个 pcm 目录，内核未导出）。\n'
    printf '  → 这只是观察通道缺失，与模块是否生效无关；链路证据已由下方 5b/5c\n'
    printf '    （dumpsys，不依赖 /proc）完整捕获 —— 直接看那两段的结论即可，此条可忽略。\n'
  else
    printf '  【D1 判定】在 %s 下找到 0 个 pcm 目录 —— 本机内核没有导出\n' "$CARD_ROOT"
    printf '  /proc/asound/.../pcm*/sub* 这棵树。这是【内核没开这条观察通道】，\n'
    printf '  不是模块没生效，也不是检测脚本的问题 —— 改多少版结果都一样。\n'
    printf '  → 本机 D 层请以下面 5b 段（dumpsys，不依赖 /proc）为准。\n'
  fi
elif [ "$ANY_OPEN" = no ]; then
  D_VERDICT="D2"
  printf '  【D2 判定】找到 %s 个 pcm 目录，此刻全部 closed —— ALSA 上没有任何流。\n' "$PCM_DIRS"
  printf '  两种可能：\n'
  printf '    a) 跑检测的时候音乐是【暂停/停止】状态 → 开始播放并保持，再跑一次；\n'
  printf '    b) 正在播放，但音频被播放器自带 USB 驱动（独占）接管 —— 没经过 ALSA，\n'
  printf '       结合第 4b 段（usbfs 绑定数）和 5c 段的 App 判定确认。\n'
else
  D_VERDICT="D3"
  printf '  【D3 判定】有 %s 条 PCM 流处于打开状态，明细如上。\n' "$PCM_OPEN_N"
fi

# --- 5b. 从 dumpsys 看"当前音频到底路由到哪、什么格式/采样率" -------------------
# 为什么要有这一段：/proc/asound/card*/pcm*/sub*/ 在很多内核上要么不存在、要么只有 root 能读，
# 所以"PCM 全 closed"经常是采集不到而不是真的没在放。dumpsys 里 Outputs 段是**不需要 root**、
# 而且在暂停后仍然保留输出对象，正好用来交叉验证"链路到底通不通、走的是哪个设备"。
# 注意：dumpsys 的输出绝不能塞进变量再 printf —— 会撞 128KB 单参数上限（MAX_ARG_STRLEN），
# 所有提取都只对临时文件做。
printf '\n--- 5b. 当前音频路由（从 dumpsys 读，不需要 root；D1/D2 状态下以这段为准）---\n'
D2=/data/local/tmp/.op13_probe_dump2.txt
USBF=/data/local/tmp/.op13_probe_usb.txt
# 活动块子集：只有 Global active count>0 的 USB 输出记录。5c 的通道判定只看它，
# 否则待命中的 hifi_playback（设备就是 USB）会让判定误报"HIFI 通道"。
USBF_ACTIVE=/data/local/tmp/.op13_probe_usb_active.txt
dumpsys media.audio_policy > "$D2" 2>/dev/null
USB_REC_N=0
USB_ACTIVE_N=0
USB_DIRECT=no
USB_MIXED=no
USB_HIFI=no
TGT_SEEN=no
# 速览数据（第 7 段用；set -u 下必须先初始化）
ACT_UID=""
ACT_FMT=""
ACT_RATE=""
ACT_NAME=""
OUT_CHAN=""
OUT_FMT=""
OUT_RATE=""
OUT_BITS=""
# uid -> 包名。/data/system/packages.list 只有 root 能读；读不到就显示 uid 原值，不报错。
uid2pkg() {
  u="$1"
  [ -n "$u" ] || return 0
  p="$(awk -v u="$u" '$2==u{print $1; exit}' /data/system/packages.list 2>/dev/null)"
  if [ -n "$p" ]; then printf '%s' "$p"; else printf 'uid:%s' "$u"; fi
}
app_name_of() {
  case "$1" in
    com.netease.cloudmusic*)  printf '网易云音乐' ;;
    com.tencent.qqmusic*)     printf 'QQ音乐' ;;
    com.hiby.music*|com.hiby*) printf '海贝音乐' ;;
    com.maxmpz.audioplayer*)  printf 'Poweramp' ;;
    com.lonelycatgames*)      printf 'UAPP' ;;
    com.apple.android.music)  printf 'Apple Music' ;;
    *)                        printf '' ;;
  esac
}
# 把 AUDIO_FORMAT_* 翻译成人话（速览用）
bits_of_fmt() {
  case "$1" in
    *FLOAT*)       printf 'float(32bit)' ;;
    *32_BIT*)      printf '32bit' ;;
    *8_24_BIT*|*24_BIT*) printf '24bit' ;;
    *16_BIT*)      printf '16bit' ;;
    *)             printf '未知位深' ;;
  esac
}
# 输出通道名（速览用）
chan_of() {
  case "$1" in
    *direct_pcm_out*) printf '直通 direct_pcm_out' ;;
    *hifi_playback*)  printf 'HiFi 通道 hifi_playback' ;;
    *deep_buffer*)    printf '混音 deep_buffer' ;;
    *low_latency*)    printf '混音 low_latency' ;;
    *)                printf 'USB 输出' ;;
  esac
}
if [ ! -s "$D2" ]; then
  printf '  dumpsys 无输出\n'
else
  printf '  正在活动的输出数（Global active count > 0）: %s\n' \
    "$(grep -c 'Global active count: [1-9]' "$D2" 2>/dev/null)"

  printf '  AudioTrack 客户端（谁在放、申请了什么格式/采样率，uid 已解析成包名）：\n'
  awk '/I\/O handle:/{c=0} /AudioTrack clients/{c=1} c && /uid [0-9]+; State:/{print "T|"$0} c && /AUDIO_FORMAT/{print "F|"$0}' "$D2" 2>/dev/null \
    | sed -n '1,40p' \
    | while IFS='|' read -r k line; do
        case "$k" in
          T) uid="$(printf '%s' "$line" | sed -n 's/.*uid \([0-9]*\).*/\1/p')"
             printf '    %s\n' "$line"
             [ -n "$uid" ] && printf '        └ uid %s = %s\n' "$uid" "$(uid2pkg "$uid")" ;;
          F) printf '        %s\n' "$line" ;;
        esac
      done

  # --- 路由到 USB 的输出记录：按 "N. Port ID:" 分块，只保留含 AUDIO_DEVICE_OUT_USB 的块 ---
  # 同时把活动块（Global active count>0）单独落到 USBF_ACTIVE —— 5c 通道判定只认活动块，
  # 避免待命中的 hifi_playback/direct_pcm_out 块（设备也是 USB）把判定带偏。
  awk -v act="$USBF_ACTIVE" '
    /^[[:space:]]*Outputs \([0-9]+\)/ { o=1; next }
    o && /^[[:space:]]*Inputs \([0-9]+\)/ { o=0 }
    o && /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ {
      if (rec != "" && rec ~ /AUDIO_DEVICE_OUT_USB/) {
        print rec "\n==END=="
        if (rec ~ /Global active count: [1-9]/) print rec > act
      }
      rec=$0; next }
    o && rec != "" { rec = rec "\n" $0 }
    END {
      if (rec != "" && rec ~ /AUDIO_DEVICE_OUT_USB/) {
        print rec "\n==END=="
        if (rec ~ /Global active count: [1-9]/) print rec > act
      }
    }
  ' "$D2" > "$USBF" 2>/dev/null

  USB_REC_N="$(grep -c '^==END==$' "$USBF" 2>/dev/null)"
  case "$USB_REC_N" in ''|*[!0-9]*) USB_REC_N=0 ;; esac
  USB_ACTIVE_N="$(awk '/Global active count: [1-9]/{n++} END{print n+0}' "$USBF" 2>/dev/null)"
  case "$USB_ACTIVE_N" in ''|*[!0-9]*) USB_ACTIVE_N=0 ;; esac
  # 通道判定只认【活动块】：hifi_playback/direct_pcm_out 待命时其记录同样路由到 USB，
  # 若在全量记录里 grep 会把"混音播放中"误判成"HIFI/直通"。判据 = 活动块里出现的端口名。
  grep -q 'direct_pcm_out' "$USBF_ACTIVE" 2>/dev/null && USB_DIRECT=yes
  grep -Eq 'deep_buffer_out|low_latency_out' "$USBF_ACTIVE" 2>/dev/null && USB_MIXED=yes
  grep -q 'hifi_playback' "$USBF_ACTIVE" 2>/dev/null && USB_HIFI=yes

  printf '  路由到 USB 的输出（共 %s 条，其中活动的 %s 条；原文）：\n' "$USB_REC_N" "$USB_ACTIVE_N"
  grep -v '^==END==$' "$USBF" 2>/dev/null | sed 's/^/    /' | head -40
  if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
    printf '    ⚠ usbfs 正接管小尾巴（4b 段）：内核里这张 USB 声卡已消失，\n'
    printf '      上面这些"活动输出"是 HAL 缓存的幽灵路由 / App 伴生流 —— 不代表真实路径。\n'
  fi
  printf '\n  判读：出现 AUDIO_DEVICE_OUT_USB_HEADSET + 期望的 AUDIO_FORMAT/采样率 = 链路通；\n'
  printf '        这里一条 USB 输出都没有 = 音频没往小尾巴送（或被 App 自带驱动抢走）。\n'

  # ================================================== 5c. 三 App 链路判定（v2.1 新增）
  printf '\n--- 5c. 三 App 链路判定（网易云音乐 / QQ音乐 / 海贝音乐）---\n'
  for u in $(awk '/AudioTrack clients/{c=1} c && /uid [0-9]+; State:/{
                  print }' "$D2" 2>/dev/null | sed -n 's/.*uid \([0-9]*\).*/\1/p' | sort -u); do
    p="$(uid2pkg "$u")"
    nm="$(app_name_of "$p")"
    [ -n "$nm" ] || continue
    TGT_SEEN=yes
    printf '  · 检测到【%s】有播放活动（%s）—— 它申请的格式/采样率见上面客户端段\n' "$nm" "$p"
  done
  [ "$TGT_SEEN" = yes ] || printf '  · 本次 dump 里没有检测到网易云/QQ音乐/海贝的播放活动（没在放、走了自带驱动独占，或当前环境无法解析包名——参考上面客户端段的 uid 行）\n'

  printf '\n  链路判定：\n'
  if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
    # usbfs 证据优先于 dumpsys 的活动输出：独占生效时，内核 USB 声卡已消失，
    # dumpsys 里的"活动输出"是 HAL 缓存的幽灵路由 / App 的伴生流，不代表真实路径。
    printf '    ✓✓ 小尾巴的接口被 usbfs 接管（第 4b 段：%s 条）—— 播放器【自带 USB 驱动独占中】。\n' "${USBFS_N:-0}"
    printf '      这就是「独占 USB 输出」生效的形态：音乐由 App 自己的驱动 bit-perfect 直连 DAC，\n'
    printf '      完全绕过 Android 音频栈 —— 本模块在此路径上【既不参与也不限制】。\n'
    printf '      注意：此刻 dumpsys 里的活动 USB 输出是幽灵路由（内核声卡已消失），\n'
    printf '      它显示直通还是混音都【不算数】，真实路径以本条 usbfs 判定为准。\n'
    printf '      想回到 Android 音频栈（走模块策略的路径）：关掉播放器的独占开关，然后拔插一次小尾巴。\n'
  elif [ "$USB_ACTIVE_N" -gt 0 ] 2>/dev/null; then
    if [ "$USB_DIRECT" = yes ]; then
      printf '    ✓ 有活动输出走【直通 direct_pcm_out】送往小尾巴 —— 模块策略在链路上。\n'
      printf '      此时位深/采样率看 D3 明细（有流时）或输出记录里的协商格式。\n'
    elif [ "$USB_HIFI" = yes ]; then
      printf '    ✓ 有活动输出走【hifi_playback HiFi 通道】送往小尾巴 —— 这是 ColorOS 为\n'
      printf '      高解析 AudioTrack 开的专用输出（实测：海贝不开独占时 192k 轨道就走它）。\n'
      printf '      它的能力按 DAC 动态上报协商 —— 输出记录里的 AUDIO_FORMAT/采样率就是\n'
      printf '      真实送达小尾巴的规格（如 24_BIT_PACKED; 96000 = 24bit/96k，上限=DAC 硬件）。\n'
    elif [ "$USB_MIXED" = yes ]; then
      printf '    ▲ 有活动输出走【混音路径 deep_buffer/low_latency】送往小尾巴：\n'
      printf '      混音路径的位深与采样率由【App 自己的 AudioTrack 请求】决定 ——\n'
      printf '      App 申请 16bit/48k 就只会是 16bit/48k，这不是模块能改的。\n'
      printf '      模块对混音路径的作用只是"混音率对齐免重采样"，给不了 24bit。\n'
    else
      printf '    ? 有 USB 输出但记录里认不出端口名，按 5b 原文里的格式行判读。\n'
    fi
  else
    printf '    ✗ 此刻没有任何输出路由到小尾巴：\n'
    if [ "$TGT_SEEN" = yes ]; then
      printf '      目标 App 有播放活动，但没有任何输出路由到 USB ——\n'
      printf '      可能在走扬声器/蓝牙，或独占申请失败后回退到了内置通道。\n'
    else
      printf '      检测时没有 App 在向小尾巴播放（暂停/停止？）→ 播放中重测。\n'
    fi
  fi

  printf '\n  三 App「感觉不到提升」的机制原因（实测于一加 13 / ColorOS 16，不是模块坏了）：\n'
  printf '   · 网易云音乐：【不开】「独占 USB 输出」= 走 Android 音频栈，超清母带轨道经\n'
  printf '     hifi_playback / direct_pcm_out 输出 —— 模块在链路上，可识别、可干预\n'
  printf '     （实测 float/192000 请求按 DAC 上限输出 24bit/96k）；【开】独占 = 自带 usbfs\n'
  printf '     驱动直连 DAC，模块在链路外（bit-perfect，与本模块无关）。\n'
  printf '   · 海贝音乐：同上 —— 不开「USB 独占」= 走栈（模块可干预）；开「USB 独占」=\n'
  printf '     自带驱动直连 DAC（模块外，DAC 直接显示真实规格）。\n'
  printf '   · QQ音乐：没有独占/直通开关，永远走混音路径 —— 位深/采样率由它自己的请求决定，\n'
  printf '     模块能给的只有混音率对齐（免重采样）。\n'
  # ============================ 速览数据采集（第 7 段用，v2.4 新增）============================
  # 活动的音频客户端：第一条 State: Active 的 uid + 紧随其后的格式/采样率
  act_lines="$(awk '/AudioTrack clients/{c=1} c && /uid [0-9]+; State: Active/{f=1; print; next} f && /AUDIO_FORMAT/{print; exit}' "$D2" 2>/dev/null)"
  ACT_UID="$(printf '%s\n' "$act_lines" | sed -n 's/.*uid \([0-9]*\).*/\1/p' | head -n1)"
  ACT_FMT="$(printf '%s\n' "$act_lines" | sed -n 's/.*\(AUDIO_FORMAT_[A-Z0-9_]*\).*/\1/p' | tail -n1)"
  ACT_RATE="$(printf '%s\n' "$act_lines" | sed -n 's/.*AUDIO_FORMAT_[A-Z0-9_]*; *\([0-9]*\).*/\1/p' | tail -n1)"
  if [ -n "$ACT_UID" ]; then
    act_pkg="$(uid2pkg "$ACT_UID")"
    act_nm="$(app_name_of "$act_pkg")"
    if [ -n "$act_nm" ]; then ACT_NAME="$act_nm(${act_pkg})"
    else ACT_NAME="$act_pkg"; fi
  fi
  # 活动的 USB 输出：活动记录里的 IOProfile + 协商格式/采样率
  if [ "$USB_ACTIVE_N" -gt 0 ] 2>/dev/null; then
    out_lines="$(awk '
      /^[[:space:]]*[0-9]+\.[[:space:]]*Port ID:/ { inrec=1; iop=""; fmt="" }
      inrec && /IOProfile/ && iop == "" { iop=$0 }
      inrec && /AUDIO_FORMAT_[A-Z0-9_]*; *[0-9]+/ && fmt == "" { fmt=$0 }
      inrec && /Global active count: [1-9]/ { print iop; print fmt; exit }
    ' "$USBF" 2>/dev/null)"
    OUT_CHAN="$(printf '%s\n' "$out_lines" | sed -n 's/.*IOProfile *name: *\([^;]*\).*/\1/p' | head -n1)"
    OUT_FMT="$(printf '%s\n' "$out_lines" | sed -n 's/.*\(AUDIO_FORMAT_[A-Z0-9_]*\).*/\1/p' | tail -n1)"
    OUT_RATE="$(printf '%s\n' "$out_lines" | sed -n 's/.*AUDIO_FORMAT_[A-Z0-9_]*; *\([0-9]*\).*/\1/p' | tail -n1)"
    OUT_BITS="$(bits_of_fmt "$OUT_FMT")"
    [ -n "$OUT_CHAN" ] && OUT_CHAN="$(chan_of "$OUT_CHAN")"
  fi
fi
rm -f "$D2" "$USBF" 2>/dev/null

# ================== 6. 谁占着小尾巴：Android 音频栈 还是 App 自带 USB 驱动
sec 6 "谁占着小尾巴（判断本模块是否在链路上）"
USB_LS="$(ls -l /proc/[0-9]*/fd 2>/dev/null | grep '/dev/bus/usb' || true)"
if [ -z "$USB_LS" ]; then
  printf '  没有进程持有 /dev/bus/usb 设备节点。\n'
  printf '  注意：/proc/PID/fd 可能被 hidepid 限制，这里"空"不一定代表真的没人占。\n'
  printf '  交叉验证请看第 4b 段：内核有没有把 snd-usb-audio 绑到 USB 音频设备上。\n'
  printf '  （被 usbfs 接管时，第 4b 段会显示 driver=usbfs 或 driver=未绑定）\n'
else
  printf '  持有 /dev/bus/usb 的进程：\n'
  printf '%s\n' "$USB_LS" \
    | sed -n 's#.*/proc/\([0-9]*\)/fd/.*-> */dev/bus/usb/.*#\1#p' \
    | sort -u | while read -r p; do
      [ -n "$p" ] || continue
      n="$(proc_of "$p")"
      case "$n" in
        *usbd*|*vold*|*init*|*zygote*) tag="（系统 USB 守护，正常）" ;;
        *audioserver*)                 tag="（音频栈持有 -> 本模块在链路上）" ;;
        *)                             tag="（第三方进程 -> 很可能是 App 自带 USB 驱动）" ;;
      esac
      printf '    pid %-7s %s %s\n' "$p" "$n" "$tag"
    done
fi

printf '\n  判定规则：\n'
printf '    · 第 5 段 owner 是 audioserver、且有 rate -> 走 Android 音频栈，\n'
printf '      本模块的 192k/384k 上限【对它有效】。\n'
printf '    · 第 5 段全程 closed，但第 6 段有第三方 App 占着 /dev/bus/usb ->\n'
printf '      该 App 用自带 USB 驱动直连 DAC。此时【本模块与它无关】：\n'
printf '      既不会被本模块的上限限制，也不会被本模块帮到。\n'

# ==================================================================== 结论
sec 7 "结论（速览 + 排查明细）"

# ---------------------------------------------------------- 速览（一眼看懂）
if [ -z "${MODDIR:-}" ]; then
  MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." 2>/dev/null && pwd)"
fi
mod_ver="$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n1)"
if [ -z "$mod_ver" ]; then
  mod_ver="$(sed -n 's/.*OP13_HIFI_SRC_BYPASS v\([0-9.]*\) :.*/\1/p' /odm/etc/audio/audio_module_config_primary.xml 2>/dev/null | head -n1)"
fi
if [ "$APPLIED" = yes ]; then
  MOUNT_LINE="✅ 已挂载（v${mod_ver:-?} · 混音 ${CONFIG_MIX:-?} / 直通上限 ${CONFIG_MAX:-?} / 位深 ${CONFIG_BITS:-?}bit）"
else
  MOUNT_LINE="❌ 未挂载 —— 先点「应用并生效」或重启，其余判断不成立"
fi
if [ -n "$ACT_UID" ]; then
  CLIENT_LINE="${ACT_NAME:-uid:$ACT_UID} 申请 ${ACT_FMT:-?} @ ${ACT_RATE:-?} Hz"
else
  CLIENT_LINE="当前没有 App 在播放（或曲目处于暂停）—— 播放中重跑本校验"
fi
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  OUTPUT_LINE="播放器自带 USB 驱动独占中（usbfs ×${USBFS_N}）—— DAC 直连，规格以 DAC 屏为准"
  VERDICT_LINE="ℹ️ 「独占 USB 输出」生效形态：音乐由 App 自带驱动直连 DAC（bit-perfect），本模块不参与也不限制"
elif [ -n "$OUT_FMT" ]; then
  OUTPUT_LINE="${OUT_CHAN:-USB 输出} → ${OUT_BITS:-?} @ ${OUT_RATE:-?} Hz 送往小尾巴"
  if [ -n "$ACT_RATE" ] && [ -n "$OUT_RATE" ] && [ "$ACT_RATE" -gt "$OUT_RATE" ] 2>/dev/null; then
    VERDICT_LINE="✅ 模块生效：App 的 ${ACT_RATE} Hz 高解析请求被接受，按 DAC 上限以 ${OUT_BITS:-?}/${OUT_RATE} Hz 输出；${ACT_RATE}→${OUT_RATE} 的降档是 DAC 硬件上限（换更高上限的解码器可到 ${ACT_RATE}）"
  elif [ -n "$ACT_RATE" ] && [ -n "$OUT_RATE" ] && [ "$ACT_RATE" = "$OUT_RATE" ] 2>/dev/null; then
    VERDICT_LINE="✅ 模块生效：App 请求与实际输出一致（${OUT_BITS:-?} @ ${OUT_RATE} Hz），无降档"
  else
    VERDICT_LINE="✅ 输出通道在跑：${OUT_CHAN:-USB} ${OUT_BITS:-?} @ ${OUT_RATE:-?} Hz（明细见排查段）"
  fi
elif [ "${NOTE_RUN:-no}" = yes ]; then
  OUTPUT_LINE="有 PCM 流在跑（明细见排查段第 5 条）"
  VERDICT_LINE="✅ 有音频流，规格见第 5 段明细"
else
  OUTPUT_LINE="此刻没有音频送往小尾巴"
  VERDICT_LINE="⚠️ 检测时没有音频在播 —— 放一首歌并保持播放，再点一次「开始校验」"
fi
printf '%s\n' "==================== 速览 ===================="
printf '%s\n' "① 模块挂载   : $MOUNT_LINE"
printf '%s\n' "② 音频客户端 : $CLIENT_LINE"
printf '%s\n' "③ 实际输出   : $OUTPUT_LINE"
printf '%s\n' "④ 判定       : $VERDICT_LINE"
printf '%s\n' "=============================================="
printf '%s\n' ""
printf '%s\n' "---- 排查明细（遇到问题把下面整段发给助手）----"

# ---------------------------------------------------------- 排查明细（保留）
if [ "$APPLIED" = yes ]; then
  printf '配置层 : 补丁已挂载\n'
else
  printf '配置层 : 补丁【未】挂载 —— 先应用或重启，其余判断都不成立\n'
fi
case "${D_VERDICT:-}" in
  D1) printf '链路层 : D1 —— 本机内核没导出 pcm 目录，/proc 观察通道不可用；以 5b/5c 为准\n' ;;
  D2) printf '链路层 : D2 —— ALSA 上没有流：检测时暂停了，或播放器自带驱动独占（4b/5c）\n' ;;
  D3) printf '链路层 : D3 —— 有 PCM 流在跑，看第 5 段每条 stream 的 rate/format 与 owner\n' ;;
  *)  printf '链路层 : 未判定\n' ;;
esac
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  printf 'USB 侧 : 小尾巴被 usbfs 接管 → 播放器自带 USB 驱动独占中（「独占 USB 输出」生效的形态）\n'
  printf '         音乐 bit-perfect 直连 DAC，本模块与它无关；dumpsys 的活动输出是幽灵路由，别看它\n'
elif [ "${USB_ACTIVE_N:-0}" -gt 0 ] 2>/dev/null; then
  if [ "${USB_DIRECT:-no}" = yes ]; then
    printf 'USB 侧 : 有活动输出走【直通 direct_pcm_out】→ 模块在链路上（5b 原文即证据）\n'
  elif [ "${USB_HIFI:-no}" = yes ]; then
    printf 'USB 侧 : 有活动输出走【hifi_playback HiFi 通道】→ 按 DAC 动态能力协商（见 5c 说明）\n'
  elif [ "${USB_MIXED:-no}" = yes ]; then
    printf 'USB 侧 : 有活动输出走【混音路径】→ 位深由 App 的请求决定（见 5c 说明）\n'
  else
    printf 'USB 侧 : 有活动输出到 USB，端口名未识别（见 5b 原文）\n'
  fi
elif [ "${NOTE_RUN:-no}" = yes ]; then
  printf 'USB 侧 : 第 5 段有流但 dumpsys 无活动 USB 输出 —— 以第 5 段为准\n'
else
  printf 'USB 侧 : 此刻没有音频送往小尾巴（暂停 / 没路由 / 设备没枚举成功）\n'
fi
if [ "${USBFS_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '归属   : 播放器自带 USB 驱动独占（usbfs×%s）——「独占 USB 输出」开启形态，模块在链路外\n' "${USBFS_N}"
elif [ -n "${ACT_NAME:-}" ] && [ -n "${OUT_FMT:-}" ]; then
  printf '归属   : %s 经 %s 通道输出 %s @ %s Hz —— 链路归属明确\n' "${ACT_NAME}" "${OUT_CHAN:-USB}" "${OUT_BITS:-?}" "${OUT_RATE:-?}"
elif [ "${USB_ACTIVE_N:-0}" -gt 0 ] 2>/dev/null; then
  printf '归属   : 有活动 USB 输出，客户端未识别（明细见 5b 客户端段）\n'
elif [ "${NOTE_MODE:-}" = android ]; then
  printf '归属   : Android 音频栈（audioserver）-> 本模块在链路上\n'
elif [ "${NOTE_MODE:-}" = app ]; then
  printf '归属   : 疑似 App 自带 USB 驱动 -> 本模块不参与\n'
elif [ "${NOTE_RUN:-no}" = yes ]; then
  printf '归属   : 有 PCM 流在跑，明细见第 5 段\n'
else
  printf '归属   : 当前没有音频送往小尾巴 —— 播放中重跑本校验\n'
fi
printf '\n下一步 : 播放中重跑本命令，看速览 ④ ——\n'
printf '         不开独占时出现 ✅ 模块生效 / ✓ HiFi 通道 / ✓ 直通 = 模块在链路上正常干预；\n'
printf '         出现 ℹ️ usbfs 接管 = 独占已开（App 直连 DAC，模块在链路外，属正常形态）；\n'
printf '         异常时把「排查明细」整段发回来可继续定位。\n'
hr
exit 0
