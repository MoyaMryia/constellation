# ThinkPad 770ED 风味

本文档记录 Constellation OS 的 **770ED 风味**：面向 IBM ThinkPad 770ED
（9548/9549 系列，1998 年，Pentium II 266 / 440BX / Trident Cyber9397DVD /
CS4237B / TI PCI1250 CardBus）。参考机配置：**64 MiB 内存（32 MiB 板载 +
32 MiB SO-DIMM）**、8.1 GB IDE 硬盘、14.1" 1024×768 TFT。

## 1. 结论先行

| 项目 | 结果 |
|---|---|
| 内核 | **Linux 6.6.162 LTS**（bzImage **1.97 MiB**，i686 / `-march=pentium2`） |
| 选 6.6 的理由 | 唯一"现代 + 完整 16 位 PCMCIA 无线生态"的 LTS（见 §3） |
| 用户空间 | musl 1.2.5 **i486** 静态 + BusyBox 1.38.0（**453 KiB**，115 applet）+ s6 2.15.1.0 |
| 内核模块 | **137 个 / 约 5 MB**（PCMCIA/CardBus/无线/声卡/猫/USB 外设） |
| 引导链 | BIOS → MBR/GRUB2 → FAT16 上的 bzImage → ext4 root → `/sbin/init` → s6-svscan → getty |
| 内存下限（实测） | **23 MiB** 到 `login:`；22 MiB 时内核解压阶段即无输出 |
| 64 MiB 时开机空闲 | `MemTotal 58 864 kB` / `MemFree 44 524 kB`（QEMU 实测，含 zram swap） |
| 镜像 | `build/constellation-770ed.img`，默认 1 GiB（`DISK_SIZE=` 可改） |

一句话：**这台机器的驱动基本齐了，缺的是三样上游已经不做的东西**
（IrDA、DEVA/MPEG-2 硬解、MWave 的用户态拨号栈），见 §6。

## 2. 硬件与驱动对照

参考来源：ThinkWiki 的 770ED/440BX/Trident Cyber9397/TI PCI1250 页、IBM
S10L-9621-02《ThinkPad 770/770E/770ED/770X/770Z Hardware Maintenance Manual》、
IBM PSREF 770ED 概述（LWIK-3TQHC7）。

| 部件 | 具体型号 | 内核驱动 | 状态 |
|---|---|---|---|
| CPU | Mobile Pentium II 266（Deschutes，512 KB L2，MMX） | `CONFIG_MPENTIUMII` | ✅ 内置 |
| 北桥 | Intel 82443BX（440BX，66 MHz FSB） | PCI 子系统 | ✅ |
| 南桥 | Intel PIIX4 系列（IDE/USB/APM） | `ATA_PIIX`、`USB_UHCI_HCD`、`APM` | ✅ 内置 |
| 内存 | 32 MiB 板载 + 64-pin SO-DIMM；288 MiB 可寻址 | `HIGHMEM=n` 足够 | ✅ |
| 显示 | Trident **Cyber9397DVD**，4 MB SGRAM，PCI `1023:9397` | **`tridentfb`**（模块） | ✅ 面板 1024×768-16 |
| 显卡 X11 | 同上 | Xorg（Alpine x86 21.1.14）+ `fbdev`（帧缓冲）/`vesa`（VBE） | ⚠️ 见 §6.1：Alpine 的 X 服务器在 PII 上会 SIGILL |
| 音频 | Crystal **CS4237B**（ISA，SB Pro 兼容） | **`snd-cs4236`** + `PNPBIOS`/`ISAPNP`；`snd-mixer-oss` 提供 `/dev/mixer` | ✅ 驱动 + `/bin/mixer` 调主音量（见 §6 的说明） |
| 猫 | IBM **MWave 3780i** DSP（56K，x2） | **`mwave`**（模块） | ⚠️ 需 BIOS 已分配 DSP 资源；无拨号用户态 |
| CardBus | **TI PCI1250**（`104c:ac16`），2×Type II / 1×Type III | **`yenta_socket`**（内置） | ✅ 通用 CardBus 桥，按 PCI class 匹配 |
| USB | PIIX4 UHCI，1 口 USB 1.1 | `USB_UHCI_HCD`（内置）+ `usbhid`/`usb-storage`/`usbserial`/`usbnet` | ✅ |
| 存储 | 8.1 GB IDE；UltraBay II 的 DVD-ROM/第二硬盘 | `ata_piix`（内置）、`BLK_DEV_SD`（内置）、`BLK_DEV_SR`（模块） | ✅ |
| 文件系统 | 系统 ext4；CF 卡/软盘/FAT；DVD-Video | `EXT4`、`VFAT/MSDOS`、`EXFAT`、`ISO9660`、`UDF` | ✅ |
| 软驱 | 内部 FDD / UltraBay II FDD | `BLK_DEV_FD`（模块） | ✅（APM 休眠也要求它在） |
| 输入 | 键盘 + TrackPoint（i8042/PS2） | `ATKBD`、`MOUSE_PS2`（含 TrackPoint） | ✅ 内置 |
| 串并口 | NS PC97338P SuperI/O | `SERIAL_8250`(+`_PNP`)、`PARPORT_PC`、`printer`、`ppdev` | ✅ 模块 |
| 电源 | **APM 1.2**（此机无 ACPI） | `APM`（内置）+ `SUSPEND`（仅为满足 Kconfig 依赖） | ✅ `/proc/apm` |
| 热键/风扇 | 嵌入式控制器（EC） | 无 `thinkpad_acpi`（它要 ACPI） | ⚠️ 见 §6 |
| 红外 | **IrDA 1.1**，前后两个收发器，最高 4 Mbps | **无**（上游 4.14 移除） | ❌ 见 §6 |
| DEVA | MPEG-2 硬解 + 视频输入/输出 | **无** | ❌ 见 §6 |
| 扩展坞 | SelectaBase 770 / SelectaDock I–III | 端口在扩展坞侧，Linux 不需要专用驱动 | ⚠️ 未实测 |

### 2.1 PCMCIA / CardBus 外接卡支持

这是本风味的重点：两个槽位上能插的东西，驱动都在镜像里，插卡即用
（内核发 uevent → `/sbin/hotplug` 按 `MODALIAS` 调 `modprobe`）。

| 卡类 | 驱动（全部 `=m`） |
|---|---|
| 16 位有线网卡（NE2000 及其克隆、3Com、Xircom、Fujitsu、SMC、AMD） | `pcnet_cs`、`axnet_cs`、`ne2k-pci`、`3c574_cs`、`3c589_cs`、`xirc2ps_cs`、`fmvj18x_cs`、`smc91c92_cs`、`nmclan_cs` |
| 16 位串口/并口/Modem 卡 | `serial_cs`（`SERIAL_8250_CS`）、`parport_cs` |
| CF / SM / ATA 存储卡 | `pata_pcmcia`（libata）+ `sd_mod`/`vfat`/`exfat`/`iso9660` |
| CardBus（32 位）网卡 | `8139too`、`r8169`、`e100`、`e1000`、`via-rhine`、`natsemi`、`sis900`、`tulip`、`pcnet32`、`3c59x` |
| CardBus USB 2.0 卡 | `ehci-pci`、`ohci-pci`（配 `usb-storage`/`usbhid`/`usbserial`/`usbnet`） |
| CardBus 无线（802.11a/b/g） | `ath5k`、`b43`/`b43legacy`、`p54pci`、`rtl8180` |
| **16 位无线（802.11b）** | `orinoco_cs`、`spectrum_cs`、`hostap_cs`、`atmel_cs`、`airo_cs`、`ray_cs`、`libertas_cs` |

> 16 位无线这一组**只有 6.6 及更早的内核才有**（见 §3）。

固件（`/lib/firmware`）随镜像带的是**能合法取到的那一部分**：

| 文件 | 提供者 | 服务的卡 |
|---|---|---|
| `regulatory.db`、`regulatory.db.p7s` | wireless-regdb 2024.05.08 | cfg80211 监管域（ath5k/rtl8180 等） |
| `agere_sta_fw.bin`、`agere_ap_fw.bin` | linux-firmware | orinoco_cs（Agere/Hermes-II 卡） |

**不需要固件的卡**：ath5k、rtl8180、pcnet_cs、3c589/3c574、8139too 等——
插上就能用。**缺固件的卡**：`b43`（Broadcom 43xx）、`atmel_cs`、
`spectrum_cs`、`p54pci`——这几种的固件已被上游 linux-firmware 移除/需要
用户自己用 `b43-fwcutter` 从 Broadcom 驱动里切，故不带；dmesg 会点名要
哪个文件，放进 `/lib/firmware` 即可，不必重编内核。

## 3. 为什么 770ED 用 6.6 LTS 而不是工程的 6.18 线

README 的主线是"版本就高不就新"，但那句的前提是"上游还愿意支持这台机器
的硬件"。770ED 的情况是：**驱动不是我们维护的，是上游删掉的**。

| 能力 | 6.6.162 LTS | 6.18.44 LTS |
|---|---|---|
| Trident Cyber9397DVD（`tridentfb`） | ✅ | ✅ |
| CS4237B（`snd-cs4236`）、MWave（`mwave`） | ✅ | ✅ |
| TI PCI1250 CardBus（`yenta_socket`） | ✅ | ✅ |
| PIIX4 UHCI USB、APM、ata_piix | ✅ | ✅ |
| **16 位 PCMCIA 无线**（orinoco_cs/hostap_cs/atmel_cs/airo_cs/ray_cs/libertas_cs/spectrum_cs） | **✅** | ❌ 上游在 6.7–6.11 之间整体移除 |
| IrDA | ❌（4.14 起移除） | ❌ |
| 支持状态 | LTS，EOL 2026-12 | LTS，EOL 2028-12 |

- 16 位无线的移除是"整段删除"，不是可修的 bug：要留它就得自己把
  orinoco/hostap/atmel/airo/ray 这一大坨搬回来并跟 cfg80211 的演进取齐。
  按用户的要求（"不强求新内核，别为了上 6.18 自己维护一堆驱动"）与
  工程原则（§3.5 尽力支持、力竭则撤），**770ED 固定在 6.6 LTS**。
- 6.18 线仍然是可构建的：`KVER=6.18.44 scripts/build-core-770ed.sh`，
  配置在 `kernel/configs/6.18.44-770ed.config`。除了 16 位无线，其余表格
  内容一致（已实测启动到 login）。
- 更老的 4.13 内核才有 IrDA（`nsc-ircc` 等），那条路要重做整套 toolchain
  与现代用户空间的兼容，收益（一个 4 Mbps 红外口）远低于代价，**不做**。

## 4. 构建

```sh
# 1) 工具链（musl i486，已存在则复用）+ BusyBox（115 applet）+ 内核与模块
JOBS=16 scripts/build-core-770ed.sh

# 2) rootfs（带 /lib/modules、s6 服务、mdev、hwcheck）
ROOT_PASSWORD_HASH="$(openssl passwd -6 '你的密码')" \
  scripts/build-rootfs-770ed.sh

# 3) 可引导镜像
scripts/mkimage-770ed.sh            # 产物 build/constellation-770ed.img
DISK_SIZE=8G scripts/mkimage-770ed.sh   # 想一次做满 8.1 GB 盘
```

改内核配置后重新生成完整配置（会逐项核对 fragment 是否真的生效）：

```sh
KVER=6.6.162 scripts/genconfig-770ed.sh
KVER=6.18.44 scripts/genconfig-770ed.sh
```

依赖：`gcc`（32 位 multilib）、`make`、`curl`、`grub-pc-bin`（`/usr/lib/grub/i386-pc`）、
`mke2fs`、`sfdisk`、`mtools`、`e2fsprogs`、`depmod`（kmod）。全程免 root。

## 5. 引导与安装

### 5.1 镜像布局

```
LBA0          GRUB2 boot.img + core.img（MBR 引导，保留分区表）
p1  2048起    FAT16  32 MiB：/bzImage、/grub.cfg、/menu.lst（grub4dos 用）
p2            ext4   LABEL=root：rootfs（/sbin/init → s6-svscan）
```

- 默认引导器是 **GRUB2 i386-pc**：它的手工布局（`boot.img` + `grub-mkimage`
  产出的 `core.img` + 原样写回 66 字节分区表）是唯一能在免 root 环境里
  装进镜像的方案（syslinux 6.03 的安装器要求 euid==0 且是 32 位二进制）。
- `gfxpayload=text` 是有意的：本风味**不开 `vesafb`**，否则 vesafb 会和
  tridentfb 抢同一块显卡，控制台会一直留在 vesafb 上。进内核后再由
  tridentfb 把 1024×768 帧缓冲控制台接过来。
- 想用 **grub4dos**：FAT 分区里已经放好 `grldr` 直接可用的 `menu.lst`
  （内核与参数和 GRUB2 完全一致，`kernel /bzImage …`）。用 `bootlace.com`
  /`grubinst` 把 grub4dos 装到 MBR 或分区引导扇区后即可引导，不必重做
  镜像，也不需要再改任何参数。

### 5.2 写到真机硬盘

镜像按"整盘"布局，直接整盘写：

```sh
# 核对目标盘（会清空整盘！）
lsblk -o NAME,SIZE,MODEL
sudo dd if=build/constellation-770ed.img of=/dev/sdX bs=4M conv=fsync status=progress
```

- 770ED 的 BIOS 支持 LBA（8.1 GB 盘本来就超过 CHS 上限），GRUB2 的
  `biosdisk` 会用 int13 扩展读盘；若遇到老 BIOS 读盘异常，优先换
  上文说的 grub4dos 路径。
- 首次开机后在目标机上跑 `hwcheck`（见 §7），它会按本文件的小节逐项
  打印证据。

## 6. 已知缺失（以及为什么不做）

| 项目 | 状态 | 原因 |
|---|---|---|
| **IrDA 1.1**（4 Mbps FIR） | ❌ 不支持 | 上游 IrDA 栈在 **4.14** 被整体移除（`nsc-ircc` 在 4.13 还在）。要留它得回到 4.13，等于放弃整个现代用户空间。 |
| **DEVA**（MPEG-2 硬解、视频输入/输出） | ❌ 不支持 | 从来没有 Linux 驱动。DVD 数据读取本身没问题（`sr_mod`+`udf`），缺的是硬解与模拟视频口。 |
| **MWave 3780i 猫** | ⚠️ 驱动在，拨号栈不在 | `mwave` 驱动仍在树内（`drivers/char/mwave`），但：①DSP 资源必须由 BIOS 侧 ThinkPad 配置工具分配过并写进 CMOS；②用户态 `mwavem`+`pppd` 不在镜像里。资源参数示例见 `/etc/modprobe.d/mwave.conf`。 |
| 图形桌面（X11） | ❌ PII 上跑不起来 | 见 §6.1：Alpine 的 x86 二进制是 Pentium III（SSE）基线，Xorg 服务器启动即 `Illegal instruction`；我们自己编的 JWM 与 Alpine 的 twm 是好的，缺的是 **i486 基线的 X 服务器**。 |
| 声音输出 | ⚠️ 有驱动、有音量控制，没有混音界面 | `snd-cs4236` 注册 `/proc/asound/cards` 与 `/dev/snd/*`；ALSA 模拟出的 `/dev/mixer` 配 `tools/mixer.c`（`/bin/mixer`，静态 30 KB）调主音量（`mixer 80`、`mixer mute`）。缺的是 alsa-utils 那套按通道（Mic/PCM/3D）细调的界面——那需要 alsa-lib，与"整个用户空间 = BusyBox + s6"的取舍冲突。 |
| 风扇/热键/特殊键 | ⚠️ 无 | 此机无 ACPI，`thinkpad_acpi` 用不上；EC（嵌入式控制器）访问要靠 2000 年代那个 out-of-tree 的 `tpctl`/`thinkpad` 模块，不在主线。风扇由 EC 自行控制，Linux 侧不影响安全。 |
| 休眠（Fn+F12） | ⚠️ 依赖 BIOS | 需要先做休眠分区（`tphdisk`/IBM 工具）并 `fdisk` 把分区类型设为 `a0`。这是 BIOS 行为，与内核无关；镜像不含 `tphdisk`。 |
| 挂起/电池状态 | ✅ `/proc/apm` | 读 `/proc/apm` 即可看电池与交流状态（`hwcheck` 会打印）。挂起动作本身由 Fn+F4 或 BIOS 触发。 |
| 无线固件 | ⚠️ 不含 | `b43`/`atmel`/`spectrum`/`p54` 需要 `/lib/firmware` 中的固件；镜像不带（许可证与体积原因）。dmesg 会点名要哪个文件。 |

## 6.1 图形桌面：已跑通（自编 i486 版 X + JWM + st）

Alpine 的 **x86** 归档基线是 Pentium III（SSE）。770ED 是 Pentium II，没有
SSE，所以"装个 X 就能用"走不通。做法：用 `tools/probe.c`（ptrace 探针，
定位 SIGILL 落在哪个 .so 的哪个偏移）逐个抓出肇事库，再用本工程 musl i486
工具链重编。**最终清单（每个都实测 SSE 指令 = 0）**：

| 层 | 重编的东西 |
|---|---|
| 压缩/图形 | `zlib`、`pixman`（`-Dsse2=disabled -Dmmx=disabled`） |
| 系统 | `libmd`、`libxcvt`、`libpciaccess` |
| 字体链 | `libexpat`、`freetype`、`fontconfig`、`libfontenc`、`libXfont2`、`libXft` |
| X 协议/客户端 | `libXau`、`libXdmcp`、`libxcb`、`libX11`、`libxkbfile`、`libICE`、`libSM`、`libXt`、`libXmu`、`libXpm`、`libXext`、`libXrender`、`libXaw` |
| 服务器与驱动 | `xorg-server 21.1.14`、`xf86-video-fbdev`、`xf86-input-keyboard`、`xf86-input-mouse`、`xkbcomp 1.4.7` |
| 桌面 | `JWM 2.4.6`（IceWM 风格任务栏/菜单）、`st 0.9.2`（终端） |

四个必须记住的坑：

1. **X 服务器必须动态链接 musl**：工具链原来是纯静态 musl，静态 libc 的
   `dlopen` 是空实现，加载驱动会报 `Dynamic loading not supported`。现在
   musl 用 `--enable-shared` 建，`/lib/libc.so` + `/lib/ld-musl-i486.so.1`
   随镜像安装（与 Alpine 的 `ld-musl-i386.so.1` 各自服务各自那批二进制）。
2. **`-fno-stack-protector`**：宿主 gcc 默认开 SSP，引用 glibc 的
   `__stack_chk_fail_local`，musl 没有这个符号。
3. **evdev 驱动硬依赖 libudev，而 eudev 也是 SSE** → 改用 `kbd` + `mouse`
   驱动，服务器 `-Dudev=false`，进程里彻底没有 udev。
4. **要挂 `devpts`**：没有它 `st`/`xterm` 报 `openpty failed`（init 里已挂
   `/dev/pts`）。

实测（QEMU `-cpu pentium2 -m 64`，`gfxpayload=1024x768x16`）：

```
# sh /usr/bin/x &            ← 起在 VT2：fbdev + kbd + mouse + JWM
==PS
  947 root  /usr/bin/jwm -f /etc/jwm/jwmrc
  949 root  st -e sh -c echo hello-from-st; sleep 40
==XLOG  0        ← Xorg 日志里 Fatal/Illegal 计数为 0
traps: (内核日志里 0 条 invalid opcode)
```

真机路径不变：`tridentfb` 提供 `/dev/fb0`（1024×768×16）→ X 走 `fbdev`
驱动；`Keyboard0`/`Mouse0` 用 kbd/mouse（TrackPoint 走 `/dev/input/mice`）。

## 6.2 指点设备：到底是 /dev/psaux 还是 /dev/input/mice？

**两个都是同一股数据流，只是名字新旧不同。** 结论先给：365X/365XD 与 770ED
的 TrackPoint 都是 **PS/2 指点设备**（接 i8042 的 AUX 口），Linux 里的数据通路是

```
i8042 AUX 口 → serio → psmouse → input 设备 → mousedev ┬→ /dev/input/mice   (13,63) 混合设备
                                                      ├→ /dev/input/mouse0  (13,32) 单个设备
                                                      ├→ /dev/input/eventN  evdev
                                                      └→ /dev/psaux         (10,1)  传统别名
```

- `/dev/psaux` 是 **mousedev 提供的兼容别名**，内容和 `/dev/input/mice`
  完全一样（内核 Kconfig 原文：*"The data available through /dev/psaux is
  exactly the same as the data from /dev/input/mice"*）。它只有在
  `CONFIG_INPUT_MOUSEDEV_PSAUX=y` 时才存在；6.6/6.18 默认**不开**，
  所以"新装的系统里找不到 /dev/psaux"是正常的。
- 90 年代的 `XF86Config` 写的是 `Option "Device" "/dev/psaux"` +
  `Option "Protocol" "PS/2"`，这就是"365X 用的是 /dev/psaux"这个记忆的来源。
  现代 X（`xf86-input-mouse`）两套都认：`PS/2` 与 `IMPS/2` 都在它的协议表里。

本风味的处理：**两个都提供，并自动选**。

1. 内核 `CONFIG_INPUT_MOUSEDEV=y` + `CONFIG_INPUT_MOUSEDEV_PSAUX=y`
   （6.6 与 6.18 两条线的 770ED 配置、以及 i486/365X 线的 L4 配置都已打开）。
2. `/usr/bin/x` 的选择顺序：`/dev/input/mice`（`IMPS/2`）→ 没有则
   `/dev/psaux`（`PS/2`）→ 再没有则退回 evdev 的 `eventN`。

实测（QEMU `-cpu pentium2`，PS/2 鼠标由 i8042 提供）：

```
crw------- 1 13, 32 /dev/input/mouse0
crw------- 1 13, 63 /dev/input/mice
crw------- 1 10,  1 /dev/psaux            ← 打开 PSAUX 后出现

N: Name="ImExPS/2 Generic Explorer Mouse"
H: Handlers=mouse0 event1

# /dev/input/mice + IMPS/2   → Mouse0: ps2EnableDataReporting: succeeded
# /dev/psaux      + PS/2     → Mouse0: ps2EnableDataReporting: succeeded
```

两条路都验证过；`ps2EnableDataReporting` 成功就说明确实在跟 AUX 口上的
PS/2 设备对话，而不是空设备。

## 7. 验收

### 7.1 已经实测的（QEMU，i440FX + PIIX3 + PII，64 MiB，真实引导链非 `-kernel`）

| 验收项 | 证据 |
|---|---|
| BIOS→GRUB→内核→ext4→s6→login | `constellation login:`；`root` 登录成功 |
| 内核身份 | `Linux constellation 6.6.162 … i686`，`model name: Pentium II (Deschutes)` |
| 内存与 zram | `MemTotal 58864 kB`；`/proc/swaps` → `/dev/zram0 16380 kB`（`zram`+`lzo_rle` 模块） |
| USB（机内 UHCI） | `uhci_hcd` 绑 00:01.2；`lsusb` 看到 root hub + 插上的 QEMU 键盘（`usbhid` 由 hotplug 自动加载） |
| 网卡（CardBus 卡的替身） | `e1000` 由冷插拔自动加载；`udhcpc` 取到 `10.0.2.15/24` |
| PCMCIA 卡驱动可加载 | `modprobe pcnet_cs|8139too|ath5k|b43|pata_pcmcia` 全部成功（无卡时静默失败） |
| 16 位无线模块存在 | `orinoco_cs`/`hostap_cs`/`atmel_cs`/`airo_cs`/`spectrum_cs` 均可加载 |
| 内存地板 | 23 MiB → `login:`；22 MiB → 串口零输出（解压阶段失败） |

### 7.2 只能在真机上确认的

QEMU 没有 440BX+TI1250+Cyber9397DVD+CS4237B 的精确模型，所以下面这些
必须上机跑一次 `hwcheck` 才算数：

| 项目 | 期望证据 |
|---|---|
| 显卡 | `/proc/fb` → `0 tridentfb`；`fbset` 显示 `1024x768-16`；控制台文字清晰、滚动不抖 |
| 声卡 | `/proc/asound/cards` 出现 `CS4237B`（PnP 探测成功）；否则按 `modprobe.d` 里的显式资源注释改 |
| CardBus | `/sys/class/pcmcia_socket/*/card_type`；插卡后 `dmesg` 出现 `pcmcia`/`yenta` 与对应驱动的 probe 行 |
| APM | `/proc/apm` 有 `1.2 …` 与电池/交流状态 |
| 猫 | `ls /dev/modems` 有 `mwave`，`dmesg` 无 DSP probe 失败 |

## 8. 踩坑清单

| 症状 | 原因 | 修法 |
|---|---|---|
| `/sbin/init: can't create /dev/null: Read-only file system`，随后掉进 `#` shell，主机名 `(none)` | init 开头的 `mount … 2>/dev/null`：此刻 `/dev` 还没挂（本风味没开 `DEVTMPFS_MOUNT`），**重定向失败会让 ash 直接跳过整条命令**，挂载没发生，后面的“挂上了吗”检查自然失败 | 早期挂载一律不带重定向，并用 `mountpoint -q` 做幂等 |
| 内核 panic：`Requested init /sbin/init failed (error -40)` | `-40` 是 `ELOOP`：rootfs 脚本先给 `/sbin/init` 建了指向 busybox 的软链，随后 `cp` **跟随软链**把模板 init 写进了 `/bin/busybox`，于是 `/sbin/init → /bin/sh → 脚本自身` 无限递归 | 软链清单里排除 `init`；拷贝模板前 `rm -f` 同名软链 |
| 所有 `CONFIG_PCMCIA_*` 卡驱动都只拿到 `=m`，或干脆消失 | `PCMCIA` 挂在 `if PCCARD` 之下，父开关不置 `y` 时会把它压到 `m` | fragment 里显式 `CONFIG_PCCARD=y` |
| `/proc/apm` 不存在，`APM` 符号怎么点都不出现 | `APM` 依赖 `PM_SLEEP`，而 `PM_SLEEP` 是 `def_bool y` + `depends on SUSPEND \|\| HIBERNATE_CALLBACKS`——不选 `SUSPEND` 就没有 APM | fragment 里加 `CONFIG_SUSPEND=y`（此机没有 ACPI，SUSPEND 只是 Kconfig 闸门） |
| 控制台停在 80×25，`/proc/fb` 里只有 `VESA VGA` | `FB_VESA` 与 `tridentfb` 同时绑同一块显卡，控制台留在 vesafb 上 | `CONFIG_FB_VESA=n`，GRUB 用 `gfxpayload=text`，进内核后由 tridentfb 接管 |
| 6.6 上 `zram0` 不存在 | 6.6 的 `ZRAM` 依赖 `CRYPTO_LZO` 且 `CRYPTO=m`，所以 zram 只能是模块（6.18 里是内置） | 配置里 `ZRAM=m`，init 里 `modprobe zram` |
| 工具链报 `cannot read spec file …/musl-gcc.specs` | 仓库被移动过：`musl-gcc.specs` 与生成的 gcc 包装器里都是**绝对路径** | `build-core-770ed.sh` 检测到路径失效就重建 musl；也可 `FORCE_TOOLCHAIN=1` |
| `head -3` / `tail -5` 报 `unrecognized option` | BusyBox 只认 `-n N` | 脚本里统一写 `head -n 3` |
| `CONFIG_PCMCIA_ATMEL=m` 在 6.6 被丢弃 | 6.6 里它 `depends on ATMEL` | 同时给 `CONFIG_ATMEL=m` |

## 9. 目录与脚本索引

| 路径 | 作用 |
|---|---|
| `scripts/build-core-770ed.sh` | musl i486（复用）+ BusyBox（115 applet）+ 内核与模块，`KVER=` 切 6.6/6.18 |
| `scripts/genconfig-770ed.sh` | 基线 + fragment → 完整配置，并逐项核对 |
| `scripts/build-rootfs-770ed.sh` | rootfs 组装（模块、s6 服务、modprobe.d、hwcheck） |
| `scripts/mkimage-770ed.sh` | 分区表 + FAT16 引导分区 + GRUB2 + ext4 root |
| `kernel/configs/6.6.162-770ed.config` / `.fragment` | 默认内核配置与增量 |
| `kernel/configs/6.18.44-770ed.config` / `.fragment` | 可选的 6.18 线（无 16 位无线） |
| `busybox/configs/busybox-1.38.0-770ed.fragment` | lspci/lsusb/fbset/hwclock/mdev/modinfo |
| `rootfs-770ed/sbin/init` | PID 1：挂载 → hotplug 助手 → 冷插拔 modalias → zram → s6 |
| `rootfs-770ed/sbin/hotplug` | uevent 助手：`MODALIAS` → `modprobe -q` |
| `rootfs-770ed/usr/sbin/hwcheck` | 上机自检报告（§7.2 的那个） |
| `tools/mixer.c` | OSS 混音器客户端（`/bin/mixer`），补 alsa-utils 的缺口 |
| `scripts/smoke-770ed.sh` | 镜像冒烟验收（真实引导链 + 登录 + 检查脚本） |
| `scripts/alpine-x86-770ed.py` | 从 Alpine x86 仓库取二进制包（钉索引/包哈希，跳过会覆盖核心用户空间的包） |
| `scripts/build-jwm-770ed.sh` | 用本工程工具链编 JWM（`/bin/jwm`），保证 PII 上无 SSE |
| `rootfs-770ed/usr/bin/x` | 启动 X（有 `/dev/fb0` 用 fbdev，否则 vesa）+ JWM，VT2 |
| `rootfs-770ed/etc/ppp/` | 串口猫/PCMCIA 猫/USB 3G 猫的 pppd 模板 |
| `rootfs-770ed/etc/modprobe.d/*.conf` | tridentfb 面板参数、CS4237B 探测、MWave 资源示例 |
