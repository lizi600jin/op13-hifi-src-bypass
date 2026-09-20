# OP13 HiFi · USB SRC Bypass
 ### ⛔ 此模块**已停止更新与维护** 项目合并至https://github.com/lizi600jin/hifi-src-bypass一同维护更新

> 一加 13 / ColorOS 16 · Qualcomm AIDL 音频 · systemless 模块
> USB 小尾巴 / 有线耳机高解析直通：**采样率上限 96k–384k 可选、位深 16/24/32bit 可切**、
> 混音率对齐消除系统级重采样。原厂策略零改写、一键还原。

---

## 1. 它到底做了什么

模块**从不修改 `/odm`**。它在 `/data/adb/op13_hifi/patched/` 下生成一份改过的
`audio_module_config_primary.xml`，然后在 **全局（init）挂载命名空间**里用
`mount --bind` 把它盖在真实文件上，让 `audioserver` 读到。

> 由此得到一个很强的性质：**还原 = 卸载绑定挂载**。原厂文件从头到尾没被动过一个字节。

### 1.1 两条互相独立的能力

很多人把 "全局 384 kHz" 当成一个开关，其实 Android 上不存在这个东西。本模块给的是两条正交的路：

**A. DIRECT / 独占直通 —— 最高可到 384 kHz**

`direct_pcm_out` 是「App 主动申请独占、跳过 AudioFlinger 混音」的通道
（flags 里带 `DIRECT`）。网易云音乐的**「独占 USB 输出」**、Apple Music 无损、
QQ 音乐 Hi-Res、海贝、UAPP、Poweramp、Neutron 走的都是这条。

原厂把它和 `usb_device_out` / `usb_headset` 一起卡在 **192 kHz + 仅 INT_16_BIT**。
v1.1 把它们提到你选的档位，并补齐 **16 / 24 / 32-bit** 三种位深。

```
原厂：  direct_pcm_out  ... 128000 176400 192000        ← 止步 192k
        usb_headset     ... 176400 192000  INT_16_BIT   ← 只有 16-bit

v1.1：  direct_pcm_out  ... 176400 192000 352800 384000
        usb_headset     ... 192000 352800 384000  INT_16 / INT_24 / INT_32
```

**B. 全局混音率对齐 —— 消除所有 App 的系统级重采样**

`low_latency_out`（主媒体输出）与 `deep_buffer_out` 的工作频率就是「系统混音率」。
把它对齐到你的曲库频率，AudioFlinger 就不再重采样：

- `48 kHz`（默认）＝ 一加原厂值，逐字节不动，最稳妥
- `44.1 kHz` ＝ 曲库以 44.1k 为主时选它

选 44.1 kHz 时，`speaker` / `earpiece` 的设备端口也会同步加上 44100，
否则策略会因为设备不支持该频率而拒绝。

> 这两条是**正交**的：A 让独占直通上到 384k；B 让普通播放（未申请独占的 App）也不重采样。
> 你不需要为了 A 去动 B。

---

---

## 2. 采样率档位（含 192 kHz）

WebUI 与 CLI 都提供 **5 档上限**，`192 kHz` 是一等公民：

| 档位 | 用途 |
|---|---|
| 96 kHz | 保守 |
| 176.4 kHz | 44.1k 系高解析 |
| **192 kHz** | 通用兼容档（高清臻音） |
| 352.8 kHz | DSD64 整数倍家族 |
| 384 kHz | **CX31993 + MAX97220 小尾巴，满血** |

> **192 kHz 无论上限选哪一档都会保留**，不会被裁掉 —— 它同时也是兼容性排查的退路。

### 一键预设

WebUI 顶部的「一键预设」和 CLI 的 `hifi preset` 等价，一次点击完成「设参数 + 应用 + 重启音频」：

| 预设 | MIXER_RATE | MAX_RATE | 场景 |
|---|---|---|---|
| `384k` | 48000 | 384000 | CX31993 满血 |
| `192k` | 48000 | 192000 | 通用兼容档 |
| `44k` | 44100 | 384000 | 曲库以 44.1k 为主，全局免 SRC |

---

---

## 3. 安装

1. 下载 `OP13_HiFi_SRC_Bypass_v1.2.zip`
2. KernelSU / Magisk / APatch → 从本地安装 → 选择 zip
3. 重启
4. 打开模块页 → **WebUI**（KernelSU / APatch 支持；Magisk 用操作按钮或终端）

安装脚本会自动定位策略文件，顺序尝试：

```
/odm/etc/audio/audio_module_config_primary.xml        ← 一加 13 走这条
/vendor/etc/audio/audio_module_config_primary.xml
/system/vendor/etc/audio/audio_module_config_primary.xml
/system/etc/audio/audio_module_config_primary.xml
（都没有则在 /odm /vendor /system 下按文件名搜索）
```

**从 v1.0 升级**：直接覆盖安装即可，`config.conf` 会保留；reboot 后生效。

---

---

## 4. 使用方法

### WebUI

- **一键预设** → 选 `384k` / `192k` / `44k`
- **直通设置** → 单独调「全局混音采样率」与「HiFi 直通上限」
- **一键还原** → 红色按钮，回到原厂
- 「USB 解码器」卡片会显示小尾巴芯片上报的最高采样率；若你设的上限高于它，会给出警告

### 命令行

```sh
H=/data/adb/modules/op13_hifi_src_bypass/bin/hifi

sh $H status              # 当前状态 + 已连接 DAC
sh $H dac                 # 探测 USB 小尾巴
sh $H verify              # 检查实际生效的配置文件（含 direct_pcm_out 上限）
sh $H doctor              # 深度体检：192k 到底有没有真正跑起来（= probe192）
sh $H rates               # 列出可选档位
sh $H preset 384k         # 满血
sh $H preset 192k         # 通用兼容档
sh $H preset 44k          # 44.1k 全局对齐
sh $H apply               # 开启：生成 + 挂载，跨重启保持
sh $H restore             # 关闭：卸载 + 回原厂，模块保留
sh $H set mixer 44100     # 单独改混音率
sh $H set max 192000      # 单独改上限
sh $H set restart 0       # 关闭“应用后自动重启音频”（更稳，重启后生效）
sh $H log                 # 运行日志
sh $H uninstall           # 手动全量清理（正常由管理器调用）
```

`apply` / `restore` 是一对开关动作，都会更新持久化状态。
`set enabled 0` 只改“下次开机是否自动挂载”，之后执行 `apply` 会重新打开。

---

---

## 5. 文件结构

```
module.prop                 模块元信息
customize.sh                安装脚本（升级时保留配置）
post-fs-data.sh             开机早期挂载（最关键的时机）
service.sh                  开机后校验，被重挂则补挂
action.sh                   管理器操作按钮 = 开关
uninstall.sh                卸载：全局卸载挂载 + 清空所有残留
bin/hifi                    控制器（status/dac/json/verify/doctor/rates/set/preset/apply/restore/uninstall）
bin/probe192.sh             192k 生效验证器（= hifi doctor，四层证据 + 结论）
payload/…xml.tmpl           策略模板（含 @MIXER_RATE@ @SPK_RATES@ @DIRECT_RATES@ @USB_RATES@ @MAX_RATE@ token）
webroot/                    KernelSU / APatch WebUI
docs/payload_diff.diff      相对一加 13 原厂的完整 diff（可审计）
```

### 运行时目录（卸载时会被整体删除）

```
/data/adb/op13_hifi/
├── patched/audio_module_config_primary.xml   生成的补丁文件
├── stock/audio_module_config_primary.xml     原厂归档（用于极端情况回写）
├── config.conf                               MIXER_RATE / MAX_RATE / ENABLED / RESTART
├── .stock_saved  .applied  .file_context     状态标记
└── last.log  dac.txt                         日志与 DAC 探测结果
```

---

---

## 6. 致谢与参考

> 本模块由 **立子** 维护与封装。采样率/位深策略本身来自一加 13 原厂配置的最小改造，
> 思路与工程实现参考了以下项目，向原作者致谢：

- **Hydro-Br-leur** —— 《一加 13T / ColorOS 16 解锁 192 kHz USB 独占模块》：
  本模块的整体思路来源（systemless 绑定挂载音频策略文件）
- **USB_SampleRate_Changer_WebUI**：WebUI 交互与 USB DAC 探测思路的参考实现
- 策略基线：**一加 13 原厂 `/odm/etc/audio/audio_module_config_primary.xml`**
  （`Copyright (c) 2023-2024 Qualcomm Innovation Center, Inc.`），
  仅做采样率/位深的最小改动，未引入任何第三方修改过的策略文件
