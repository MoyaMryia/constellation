# Constellation OS

<p align="center"><img src="assets/logo.svg" width="160" alt="Constellation OS Logo"></p>

> 尽可能在满足旧机器要求的前提下，把软件栈版本拉到最高。

Constellation OS 是一个面向老旧 x86 硬件的 Linux 发行版项目。其核心命题是：

**软件栈的"版本新旧"与"资源占用"是两个近似独立的变量。**
主流发行版（包括面向复古硬件的移植）的高内存地板，大多来自选型（systemd、glibc、桌面环境），而非来自上游版本本身。Constellation OS 通过激进的轻量化选型（musl、BusyBox、s6/runit 等），让一台 1996 年的笔记本也能运行 2025 年的内核与用户空间。

## 目标参考机型

| 项目 | 365X/365XD（低内存档） | 770ED（PCMCIA/多媒体档） |
|---|---|---|
| 代表机型 | IBM ThinkPad 365X / 365XD | IBM ThinkPad 770ED |
| CPU | Pentium 133 MHz（无 MMX，i586，带 FPU 与 TSC） | Mobile Pentium II 266（Deschutes，MMX，512 KB L2） |
| 内存 | 24 MiB（基础档）/ 40 MiB（扩展档） | 64 MiB（32 板载 + 32 SO-DIMM），23 MiB 即可启动 |
| 存储 | ~1 GiB IDE 硬盘 | 8.1 GB IDE 硬盘 + UltraBay II DVD-ROM |
| 图形 | VGA 文本 | Trident Cyber9397DVD，14.1" 1024×768 TFT |
| 扩展 | 16 位 PCMCIA | 2×Type II CardBus（TI PCI1250）+ USB 1.1 |
| 内核风味 | 6.18.44 Pentium / legacy486 | 6.6.162（保 16 位 PCMCIA 无线），另有 6.18.44 可选 |
| 用户空间基线 | **i486**（两条线共用） | **i486**（musl 1.2.5 + BusyBox + s6） |

## 设计原则

1. **版本就高不就新**：每个组件在满足"主流维护中 + 实测协调旧机"的约束下选用尽量高的版本——不盲目追最新，也不无故冻结旧版；所有降级决策必须书面记录。
2. **分档而非单一需求表**：需求按内存档位和形态（CLI/图形）分别给出，避免"一张表管所有配置"造成的失真。
3. **内存预算制**：所有选型以 24 MiB 内存预算为硬约束进行核算，见 [docs/memory-budget.md](docs/memory-budget.md)。
4. **可复现构建**：全部软件包由交叉编译工具链从源码构建，构建脚本即文档。
5. **尽力支持，力竭则撤**：对每一档硬件和每一个架构，跟随上游能跟到哪天是
   哪天——上游放弃时先尝试自维护补丁/停留 LTS，维护成本真正不可承受时才
   撤退；撤退也按章程来（冻结最后可用版本、留档、明确告示），不搞突然死亡。
   详见 [docs/design.md](docs/design.md) §3.5。

## 品牌资源

- [assets/logo.svg](assets/logo.svg) / [assets/logo.png](assets/logo.png) — 拼色 `*` 号主标识
- [assets/fastfetch.txt](assets/fastfetch.txt) — fastfetch 终端字符画 logo（明暗渐变风格，ANSI truecolor），
  用法：`fastfetch --logo assets/fastfetch.txt`，或在 config.jsonc 中设
  `"logo": { "source": "/path/to/assets/fastfetch.txt" }`

## 文档

- [docs/design.md](docs/design.md) — 总体设计文档（选型论证、架构基线、路线图）
- [docs/thinkpad-770ed.md](docs/thinkpad-770ed.md) — 770ED 风味（驱动矩阵、PCMCIA 卡支持、6.6/6.18 选型、上机验收）
- [docs/memory-budget.md](docs/memory-budget.md) — 内存预算明细
- [kernel/NOTES.md](kernel/NOTES.md) — 内核裁剪研究笔记（M1 / D10 实测数据）
- [busybox/NOTES.md](busybox/NOTES.md) — BusyBox/musl initramfs 研究笔记（M1）
- [docs/m2-notes.md](docs/m2-notes.md) — M2 最小系统笔记（s6/rootfs/syslinux 磁盘启动）
- [BUILDING.md](BUILDING.md) — 从干净仓库构建核心组件、M2 rootfs 与部署镜像

## 状态

早期设计阶段。**M1 可引导核心已跑通**：精简 LTS 内核（6.18.44）+
musl i486 静态 BusyBox initramfs，QEMU 24 MiB 启动到 shell（见
[kernel/NOTES.md](kernel/NOTES.md) 与 [busybox/NOTES.md](busybox/NOTES.md)）；
**L1 内核层 + syslinux 引导已跑通**：IDE/libata + ext4 + DOS 分区，
BIOS → MBR → SYSLINUX → bzImage → ext4 root → BusyBox PID 1（见
kernel/NOTES.md）。**L2 外设已开工（仅 6.18.44）**：PCMCIA/i82365、
8390 网卡（`NE2K_PCI` 等已改为模块并验证 `insmod` 后识别 `eth0`）、
VGA fb 已编入/构建为模块；**L3 内存机制已跑通**：zram(lz4) + swap
在 QEMU 下成功启用；**L4 用户空间契约已跑通**：BusyBox init + getty 在
QEMU 下启动到 `(none) login:`。BusyBox 带 insmod/rmmod/lsmod/modprobe/mkswap/swapon/swapoff/free/getty/login。
尚无发布用安装镜像；M2 的 s6-svscan + getty rootfs 模板已受追踪，硬盘启动
仍待专用镜像验收。当前已通过的核心验收是 M1 initramfs 在 QEMU 中启动到 shell；
受追踪的
rootfs 模板和组装脚本已补齐（见 docs/m2-notes.md 与 BUILDING.md）。网络协议栈、
DHCP 工具和模块加载路径已纳入配置，PCMCIA 联网仍待 86Box/真机验收。

### 770ED 风味（2026-11）

**770ED 已产出可引导镜像** `build/constellation-770ed.img`：Linux **6.6.162 LTS**
（i686，bzImage 1.97 MiB）+ 137 个模块 + musl i486 BusyBox/s6，BIOS → MBR/GRUB2
→ bzImage → ext4 root → s6-svscan → `login:` 在 QEMU 下逐条验收通过；23 MiB
即可启动。驱动覆盖 Trident Cyber9397DVD（tridentfb）、CS4237B（snd-cs4236）、
MWave 3780i、TI PCI1250 CardBus（yenta）、PIIX4 UHCI USB、APM 1.2、CS4237B 的
`/dev/mixer` 音量控制，以及成组的
PCMCIA/CardBus 外接卡驱动（16 位有线/串并口/CF/无线 + CardBus 网卡/无线/USB2）。
缺 IrDA（上游 4.14 移除）、DEVA 硬解（从无驱动）与 MWave 用户态拨号栈；
详见 [docs/thinkpad-770ed.md](docs/thinkpad-770ed.md)。
