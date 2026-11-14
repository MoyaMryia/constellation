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
| 图形 | VGA 文本 | Trident Cyber9397（4 MB SGRAM），14.1" 1024×768 TFT |
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

## 许可

本项目自己写的代码是 **GPL-3.0**（全文见 [LICENSE](LICENSE)）；第三方组件
（`rootfs-770ed/lib/firmware/` 下的 Broadcom/Agere 固件、wireless-regdb、
`third_party/` 的补丁等）保持各自原有许可，清单见 [NOTICE](NOTICE)。

## 文档

- [docs/design.md](docs/design.md) — 总体设计文档（选型论证、架构基线、路线图）
- [docs/thinkpad-770ed.md](docs/thinkpad-770ed.md) — 770ED 风味（驱动矩阵、PCMCIA 卡支持、6.6/6.18 选型、上机验收）
- [docs/memory-budget.md](docs/memory-budget.md) — 内存预算明细
- [kernel/NOTES.md](kernel/NOTES.md) — 内核裁剪研究笔记（M1 / D10 实测数据）
- [busybox/NOTES.md](busybox/NOTES.md) — BusyBox/musl initramfs 研究笔记（M1）
- [docs/m2-notes.md](docs/m2-notes.md) — M2 最小系统笔记（s6/rootfs/syslinux 磁盘启动）
- [docs/amd64-x61.md](docs/amd64-x61.md) — x61 风味（64 位总线、gfxpayload 可调、i3/tinywm 路线边界）
- [BUILDING.md](BUILDING.md) — 从干净仓库构建核心组件、M2 rootfs 与部署镜像

## 状态

- **M1 核心**：精简 LTS 内核 + musl i486 静态 BusyBox initramfs，QEMU 24 MiB 启动到 shell。
- **M2 最小系统**：s6-svscan + getty，硬盘（BIOS → MBR → 引导器 → bzImage → ext4 root）启动到 `login:`。
- **770ED 风味**：可引导镜像 + 真机验证（见下节）。
- **x61 风味**：64 位总线（AMD64 核心 + s6 + syslinux），见 [docs/amd64-x61.md](docs/amd64-x61.md)。

尚未发布安装器；镜像由脚本拼装后 `dd` 写盘（`scripts/install-disk-770ed.sh`）。

### 770ED 风味（2026-11）

**已产出两张可引导镜像**，都在真机（ThinkPad 770ED，PII 266 / 64 MiB）上验过启动：

| 镜像 | 内核 | 内容 |
|---|---|---|
| `build/constellation-770ed-g4d.img` | Linux **6.6.162 LTS**（i686） | musl i486 + BusyBox 405 applet + s6 + Xorg/JWM + 开发工具 |
| `build/constellation-770ed-lcars.img` | Linux **2.2.26**（`CONFIG_M686`） | [BasicLinux 3.5 LCARS](https://github.com/queenkjuul/basiclinux-lcars)，见 [doc §13](docs/thinkpad-770ed.md) |

770ED 镜像的内容要点：

- **引导**：grub4dos（`grldr.mbr` @ LBA0）。分区按 DOS 几何排：`p1` 从 **LBA 63**
  起（FAT16/LBA，`hidden sectors=63`）、`p2` swap 256 MiB、`p3` ext4 根，全部对齐到
  柱面（63 spt × 16 heads）。目标机上是 `/dev/sda1/2/3`（libata）。
- **驱动**：`tridentfb`（1024×768-16 面板模式，走 `/etc/modprobe.d`）、`snd-cs4236`
  + `snd-{mixer,pcm}-oss`（`/dev/mixer`、`/dev/dsp`）、`mwave`、TI PCI1250 双槽
  CardBus（`yenta_socket`）、PIIX4 UHCI USB、APM 1.2、`ata_piix`，以及成组的
  PCMCIA/CardBus 外接卡驱动（16 位有线/串并口/CF/无线 + CardBus 网卡/无线/USB2）。
- **桌面**：自编 i486 X 栈（23 个库 + xorg-server 21.1.14 + JWM + st），
  输入用 `kbd`/`mouse`（不用 evdev：它硬依赖 libudev）。
- **零 SSE**：整份镜像按"不含 SSE/AVX/3DNow 指令"审计
  （`scripts/audit-sse-770ed.sh`，PII 没有 SSE，Alpine 的 x86 包是 PIII 基线）。
- **用户空间**：`sudo`（setuid 小助手 + `/etc/constellation/sudoers`）、
  `poweroff`/`reboot` 走 s6 关停流程后直接 `reboot(2)`、U 盘插入自动挂
  `/media/usb`、`osupdate` 从 U 盘的 `.upd` 增量更新（校验 + 备份 + 回滚）、
  `fetch`（Mark + 概况）、`wifi`（b43/WPA2）、离线开发工具（`tcc`/`make`/binutils/
  musl 头文件）、`mpg123`/`tone`/`fbset`/`lspci`、`ccode-cli`。

构建与写盘（全部在 x86_64 Linux 宿主上交叉编译）：

```sh
KVER=6.6.162 scripts/build-core-770ed.sh            # 工具链 + busybox + 内核 + 模块
sudo ROOT_PASSWORD_HASH="$(openssl passwd -6 'pw')" \
     EXTRA_USERS="user:$ROOT_PASSWORD_HASH" scripts/build-rootfs-770ed.sh
sudo GRUB4DOS=1 scripts/mkimage-770ed.sh            # → build/constellation-770ed-g4d.img
sudo IMAGE=$PWD/build/constellation-770ed-g4d.img scripts/install-disk-770ed.sh /dev/sdX --grub4dos
sudo sfdisk --activate /dev/sdX 1                   # 活动标志只留 p1
```

> build-rootfs / mkimage 需要 root：镜像里的文件属主必须是 `0:0`，`su`/`sudo`
> 依赖 `/bin/busybox` 的 setuid 位。

升级系统不必重刷：在目标机上 `osupdate`（读 U 盘上的 `constellation-*.upd`，
先逐文件校验 sha256，再备份 + 原子替换，可用 `--rollback` 回退）。

缺 IrDA（上游 4.14 移除）、DEVA 硬解（从无驱动）与 MWave 用户态拨号栈。
详见 [docs/thinkpad-770ed.md](docs/thinkpad-770ed.md)（858 行，含逐项实测记录、
内核裁剪踩坑、SSE 审计方法、BasicLinux LCARS 风味）。
