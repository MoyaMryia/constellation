# Constellation OS

<p align="center"><img src="assets/logo.svg" width="160" alt="Constellation OS Logo"></p>

> 尽可能在满足旧机器要求的前提下，把软件栈版本拉到最高。

Constellation OS 是一个面向老旧 x86 硬件的 Linux 发行版项目。其核心命题是：

**软件栈的"版本新旧"与"资源占用"是两个近似独立的变量。**
主流发行版（包括面向复古硬件的移植）的高内存地板，大多来自选型（systemd、glibc、桌面环境），而非来自上游版本本身。Constellation OS 通过激进的轻量化选型（musl、BusyBox、s6/runit 等），让一台 1996 年的笔记本也能运行 2025 年的内核与用户空间。

## 目标参考机型

| 项目 | 规格 |
|---|---|
| 代表机型 | IBM ThinkPad 365X / 365XD |
| CPU | Pentium 133 MHz（无 MMX，i586，带 FPU 与 TSC） |
| 内存 | 24 MiB（基础档）/ 40 MiB（扩展档） |
| 存储 | ~1 GiB IDE 硬盘 |
| 二进制基线 | **i486**（保证在真 486 至 Pentium 全区间可运行） |

## 设计原则

1. **版本就高不就新**：每个组件在满足"主流维护中 + 实测协调旧机"的约束下选用尽量高的版本——不盲目追最新，也不无故冻结旧版；所有降级决策必须书面记录。
2. **分档而非单一需求表**：需求按内存档位和形态（CLI/图形）分别给出，避免"一张表管所有配置"造成的失真。
3. **内存预算制**：所有选型以 24 MiB 内存预算为硬约束进行核算，见 [docs/memory-budget.md](docs/memory-budget.md)。
4. **可复现构建**：全部软件包由交叉编译工具链从源码构建，构建脚本即文档。
5. **尽力支持，力竭则撤**：对每一档硬件和每一个架构，跟随上游能跟到哪天是
   哪天——上游放弃时先尝试自维护补丁/停留 LTS，维护成本真正不可承受时才
   撤退；撤退也按章程来（冻结最后可用版本、留档、明确告示），不搞突然死亡。
   详见 [docs/design.md](docs/design.md) §3.5。

## 文档

- [docs/design.md](docs/design.md) — 总体设计文档（选型论证、架构基线、路线图）
- [docs/memory-budget.md](docs/memory-budget.md) — 内存预算明细
- [kernel/NOTES.md](kernel/NOTES.md) — 内核裁剪研究笔记（M1 / D10 实测数据）
- [busybox/NOTES.md](busybox/NOTES.md) — BusyBox/musl initramfs 研究笔记（M1）

## 状态

早期设计阶段。**M1 可引导核心已跑通**：精简 LTS 内核（6.18.44）+
musl i486 静态 BusyBox initramfs，QEMU 24 MiB 启动到 shell（见
[kernel/NOTES.md](kernel/NOTES.md) 与 [busybox/NOTES.md](busybox/NOTES.md)）；
**L1 内核层 + syslinux 引导已跑通**：IDE/libata + ext4 + DOS 分区，
BIOS → MBR → SYSLINUX → bzImage → ext4 root → BusyBox PID 1（见
kernel/NOTES.md）。**L2 外设已开工（仅 6.18.44）**：PCMCIA/i82365、
8390 网卡（`NE2K_PCI` 等已改为模块并验证 `insmod` 后识别 `eth0`）、
VGA fb 已编入/构建为模块；**内核保留模块加载器，BusyBox 带
insmod/rmmod/lsmod/modprobe**。尚无可用安装镜像。
