# Constellation OS 内存预算

本文档是设计的硬约束：所有选型决策以 **T0 = 24 MiB** 预算核算，T1 = 40 MiB
为图形档。数字为工程估算（基于同类精简系统的公开实测经验），**M2 里程碑
完成后必须用实机/86Box 实测数据回填替换**。

## 1. T0 档：24 MiB 总预算

| 占用方 | 预算 (MiB) | 说明 |
|---|---|---|
| 内核常驻（代码+数据+页表+驱动） | 6–8 | 精简 .config、XZ 压缩；含 PCMCIA/IDE/fb 驱动 |
| 页缓存/缓冲区（内核弹性占用） | 3–4 | 下限水位，靠 zram swap 顶住压力 |
| init 与服务（s6 全家桶 + getty + udhcpc） | 1.5–2 | s6-svscan、s6-rc、日志服务常驻 |
| libc + BusyBox（共享驻留） | 2–3 | musl 全量 < 1 MiB；BusyBox 多调用二进制 ~1 MiB |
| apk 包管理（操作期峰值） | 2–3 | 安装/升级事务时为峰值占用方 |
| 用户交互余量（shell + 一个应用） | 4–6 | vi、less、ssh(dropbear 级) 或 links 文本模式 |
| **合计** | **≈ 20–24** | 峰值场景需 zram swap 参与 |

### 关键机制

- **zram swap**（LZ4）：约划 8–12 MiB 内存作压缩交换设备，换出匿名页
  （典型 2:1 压缩率），等价"扩容"到 ~30 MiB 有效内存。代价是 Pentium 133
  上的 CPU 开销——LZ4 解压 ~数百 MB/s 理论值，133 MHz Pentium 实测远低，
  仍是可接受的权衡（相比 IDE 硬盘 swap 快一个数量级以上）。
- **IDE swap 后备**：zswap writeback 或低优先级 disk swapfile，吸收冷页。
  参考机型硬盘慢（~10 MB/s 级 PIO），仅作兜底。
- **无磁盘缓存奢侈**：页缓存水位压到最低，放弃"用空闲内存加速 IO"的现代
  惯性——24 MiB 里没有空闲内存这回事。

## 2. T1 档：40 MiB（T0 + 16 MiB 图形预算）

| 增量占用方 | 预算 (MiB) | 说明 |
|---|---|---|
| 帧缓冲应用运行时（links2 -g / fbi 及 cairo/freetype 栈） | 6–10 | 走 fb 直连路线（设计文档 D4 首选） |
| 若走 TinyX 路线：X 服务器 + 微型 WM | 8–12 | 需实测；可能迫使二选一 |
| zram swap 扩容 | +8 | 有效内存目标 ~50 MiB |

## 3. 对比锚点

| 系统 | 最低内存 | 软件栈年代 |
|---|---|---|
| 星霞 OS（统一表） | 64 MiB | 现代 |
| **Constellation T0（预算值）** | **24 MiB** | **现代（同代或更新）** |
| Tiny Core Linux | ~16–46 MiB | 现代（微内核式裁法，功能面更窄） |
| BasicLinux（BL3，可开 X） | **~8 MiB** | **2003 年前后：内核 2.2/2.4 + XFree86 3.3 + libc5 系** |
| 历史参考：1997 年典型桌面 Linux | 16–32 MiB | 2.0/2.2 内核时代 |

Constellation 的独特位置：以 Tiny Core 量级的内存地板，提供完整包管理与
现代用户空间；以低于星霞 60% 的内存，运行同代软件栈。

### 3.1 为什么不是 8 MiB：BasicLinux 对照与"现代性的价格"

BasicLinux 证明了 8 MiB 跑图形界面在工程上成立——但拆开它的栈就能看到
代价全部在版本维度上：

| BasicLinux 组件 | 内存特征 | 与现代对应的差距 |
|---|---|---|
| 内核 2.2/2.4 | 常驻 ~1–2 MiB | 现代 6.x 精简地板 6–8 MiB：页结构、子系统、安全特性的静态增长，**不可裁剪** |
| XFree86 3.3.x | 数 MiB 级 | 现代 Xorg 21.x 大数倍；kdrive/TinyX 路线已被上游移除 |
| libc5 / 早期 glibc | 极小 | musl 虽已最小化，仍大于 libc5 时代 |
| 无 TLS 生态 | 0 | 现代网络意味着 TLS 1.3（mbedTLS 最小也是非零成本） |

结论：**8 MiB 现代栈无解，16 MiB 现代 CLI 或可行但需重度 swap**。24 MiB
是"现代版本 + 体验尚可"的甜点，这就是 T0 定档的依据。内存比 24 MiB 更小
的机器，理性选择是 BasicLinux 这类"冻结版本换体积"的发行版——这不是
Constellation 的失败，而是坐标系上另一个合法的极端点。

**待验证假设（M1/M2 回填）**：若实测 16 MiB + zram 下 CLI 可用性出乎意料
地好，则增设 TX 极限档（16 MiB，CLI-only，明确标注"重度 swap、体验受限"）。
见设计文档 D7。

## 4. 实测回填计划（M2 完成时）

- [x] 内核 bzImage 尺寸与启动后 `/proc/meminfo` 基线（L0 已回填；L1–L4 完成后补全全量基线）
- [ ] s6 全家桶常驻 RSS
- [ ] apk 安装事务峰值 RSS（`time -v` / cgroup 统计）
- [ ] zram 压力下交互延迟主观评估
- [ ] 回填本表并签发 T0 正式需求表

### 4.1 L0 实测快照（2026-08，详见 kernel/NOTES.md）

QEMU 6.2 `-cpu pentium -m 24`，L0 = tinyconfig + 串口/init/devtmpfs/proc/sysfs：

| vintage | bzImage（XZ） | 用户态可用内存 @24M |
|---|---|---|
| 6.1.182 | 0.76 MiB（799,232 B） | 20,700 K |
| 6.18.44 | 0.82 MiB（864,768 B） | 20,280 K |

年代红利约 420 K，低于 D10 的 2 MiB 阈值，D10 暂倾向 6.18。内核常驻明细与
M686 choice 坑见 kernel/NOTES.md。

**M1 initramfs 快照（同上环境）**：musl i486 静态 BusyBox 1.38.0
（193 KiB），initramfs gzip 后 114 KiB；启动到 shell 后 MemFree ≈ 18.6 MiB
（6.1 18,672 kB / 6.18 18,676 kB），距 24 MiB 预算还很宽裕。glibc 静态
BusyBox 在 Pentium 上因 i686 基线（CMOV）崩溃，用户空间必须用 i486 基线 libc。

**L1 存储/引导快照（2026-08，详见 kernel/NOTES.md）**：L0 基础上开启
`BLOCK`/`PCI`/libata(`ATA_PIIX`)/`BLK_DEV_SD`/`EXT4_FS`。QEMU 同一环境：

| vintage | bzImage（XZ） | 内核可用内存（`Memory:` 行，带 initramfs） | 磁盘 ext4 root（无 initramfs） |
|---|---|---|---|
| 6.1.182 | 1.16 MiB（1,221,120 B） | 19,620 K / 24,056 K | `Memory: 19732K/24056K`，ext4 挂载成功，`/bin/sh` 启动 |
| 6.18.44 | 1.29 MiB（1,356,288 B） | 19,008 K / 24,056 K | 已开 `CONFIG_MODULES`；ext4 root 验证见 kernel/NOTES.md |

L1 年代红利（同清单口径，均为无 MODULES 时）468 K（6.1 更多），仍低于
D10 阈值。**模块策略（2026-08 更新）：保留模块加载器**——`CONFIG_MODULES`
+ `CONFIG_MODULE_UNLOAD` 的成本约 144 K 用户态内存 + 52 KiB bzImage，
在 24 MiB 预算内可接受；用户可 `insmod`/`modprobe` 额外驱动。

**L2 外设快照（2026-08，仅 6.18.44，详见 kernel/NOTES.md）**：L1 基础上
增加 `PCCARD`/`PCMCIA`/`I82365`、8390 家族网卡（`NE2000`/`NE2K_PCI`/
`PCMCIA_PCNET`）、`FB`/`FB_VESA`/`FB_VGA16`，并保留模块加载器。bzImage
1,614,336 B（1.54 MiB），仍 < 2.5 MiB；`Memory: 18404K/24056K available`。
QEMU 下 NE2K PCI/ISA 均识别 `eth0`，i82365 完成 probe；BusyBox 已带
`insmod`/`rmmod`/`lsmod`/`modprobe` 符号链接；fb 实绑待 86Box/VESA。
