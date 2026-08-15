# 内核裁剪研究笔记（M1 / D10）

目标：从最小配置起步构建面向 Pentium/i486 的极简 LTS 内核，实测体积与内存，
量化 vintage 之间的"年代红利"，为 D10（6.18 vs 6.1）提供决策数据。

## 验收目标（设计文档 §3.2）

- bzImage（XZ 压缩）≤ 2.5 MiB
- 启动后内核常驻 ≤ 8 MiB @ 24 MiB 机型

## 候选源码

| vintage | 版本 | 上游 EOL | 备注 |
|---|---|---|---|
| 6.1 | 6.1.182 | 2027-12（CIP 接力至 ~2033） | 体积候选 |
| 6.18 | 6.18.44 | 2028-12 | 上游窗口候选 |

源码树位于 `kernel/src/`（tarball 不删，归档策略兼容）。

## 方法论

1. **起点用 `tinyconfig`**（`make tinyconfig`）：从近乎为空开始**加法**，
   而非从 defconfig 做减法——加法过程天然产出"每一项为什么存在"的记录；
2. 按功能层逐组开启并记录增量（每层构建一次，量尺寸）：
   - L0 可引导：串口控制台、无驱动（QEMU `-kernel` 直通启动即验证）；
   - L1 参考机型存储/引导：IDE/libata（或 ATA 旧栈）、ext4、syslinux 可引导；
   - L2 参考机型外设：16 位 PCMCIA、NE2000（`pcnet_cs`/8390）、VGA fb；
   - L3 内存机制：zram（LZ4）、swap 支持；
   - L4 用户空间契约：s6/BusyBox 所需（devtmpfs、proc/sysfs、
     必需的 namespace/cgroup 子集——以"init 能起、getty 能开"为验收）；
3. 测量：
   - 镜像尺寸：`ls -l arch/x86/boot/bzImage`；
   - 常驻内存：QEMU `-m 24` 启动后立即读 `/proc/meminfo` 的
     MemTotal/MemFree（initramfs 里静态 BusyBox 直接报数）；
   - 86Box（Pentium 133 精确模拟）留作最终确认，QEMU（`-cpu pentium`）
     用于快速迭代；
4. 两个 vintage 用**同一份增量清单**各走一遍，常驻内存差即年代红利。

## 配置存档

`kernel/configs/` 下按 `vintage-Lx.config` 命名提交 git，每层附增量说明
（提交信息即裁剪日志）。

## 实测数据（回填）

环境：QEMU 6.2 `-cpu pentium -m 24`，串口控制台，L0 = tinyconfig +
串口/init/devtmpfs/proc/sysfs/BINFMT_SCRIPT，CPU 均为 Pentium Classic
（`M586TSC`）。bzImage 压缩为 **XZ**（配置档案中已开 `CONFIG_KERNEL_XZ`）。

| vintage | 层级 | bzImage | 用户态可用内存 @24M | 内核明细 | 备注 |
|---|---|---|---|---|---|
| 6.1.182 | L0 | 0.76 MiB（799,232 B，XZ） | **20,700 K / 24,056 K** | code 1178K, rwdata 561K, rodata 248K, init 184K, bss 244K, reserved 3356K | 启动正常，panic 仅为无 init（预期） |
| 6.18.44 | L0 | 0.82 MiB（864,768 B，XZ） | **20,280 K / 24,056 K** | code 1324K, rwdata 556K, rodata 272K, init 192K, bss 204K, reserved 3496K | 同上 |

**L0 年代红利：420 K（6.1 比 6.18 多出 420K 用户态可用内存）**——远低于
D10 的 2 MiB 阈值。若 L1–L4 数据不反转，D10 倾向 **6.18**（上游维护窗口
多约 2 年）。bzImage 两者均远低于 2.5 MiB 目标。

### 过程记录

- 6.1：`make tinyconfig` 的默认 CPU 选择即兼容 Pentium，直接可建；
- 6.18：tinyconfig 默认 `M686`，`scripts/config --enable M586TSC` 无效
  （Kconfig choice 需先 `--disable M686`），症状为 bzImage 启动即拒绝
  （"requires an i686 CPU"）——修复后正常。此坑已记录，后续层级配置
  注意 choice 类符号的改法；
- 两个树均在 16 线程宿主机上 ~2 分钟完成 L0 构建，迭代成本可忽略；
- L0 配置补开 `CONFIG_BINFMT_SCRIPT`：initramfs 的 `/init` 可直接写成
  `#!/bin/busybox sh` 脚本，不必先备静态 ELF init。两个 vintage 均已
  重建验证，bzImage 尺寸与开之前一致（6.1 799,232 B / 6.18 864,768 B）。

## M1 可引导核心（initramfs 启动，2026-08 回填）

M1 验收：精简 LTS 内核 + BusyBox initramfs，24 MiB 启动到 shell。
本次用 **musl i486 静态 BusyBox 1.38.0**（glibc 静态 i386 在 Pentium 上
因 Ubuntu glibc 为 i686 基线含 CMOV，实机/`-cpu pentium` 下 `trap invalid
opcode`，不可用；musl 从源码以 `-march=i486` 构建后无 CMOV，见
`busybox/NOTES.md`）。initramfs 仅 114 KiB（gzip）。

QEMU 6.2 `-cpu pentium -m 24`，串口控制台，`console=ttyS0,115200`。
两个 vintage 均成功执行 `/init`、挂载 proc/sysfs/devtmpfs 并落到 ash。

| vintage | bzImage（XZ） | 内核可用内存（`Memory:` 行） | /proc/meminfo MemTotal | /proc/meminfo MemFree | 备注 |
|---|---|---|---|---|---|
| 6.1.182 | 799,232 B（0.76 MiB） | 20,588 K / 24,056 K | 20,884 kB | 18,672 kB | shell 输入回显正常 |
| 6.18.44 | 864,768 B（0.82 MiB） | 20,168 K / 24,056 K | 20,752 kB | 18,676 kB | 同上 |

- 内核可用内存差仍为 **420 K**（6.1 更多），与 L0 一致；D10 阈值 2 MiB，
  继续倾向 6.18。
- M1 验收项：bzImage ≤ 2.5 MiB **达成**（两树均 < 1 MiB）；内核常驻
  ≤ 8 MiB **达成**（24,056 − MemTotal ≈ 3.2–3.3 MB，含内核与保留内存）。
- BusyBox 静态二进制（musl i486）197,844 B，连同 `/init` 与 cpio 开销，
  initramfs gzip 后 113,938 B。
- glibc 静态方案失败记录：Ubuntu 32 位 glibc 静态库为 i686 基线
  （含 `cmove`），在 `-cpu pentium` 上 init 崩溃；本项目用户空间基线是
  i486，必须用 musl（或其它 i486 基线 libc），M0 交叉工具链应基于 musl。

## L1 存储/引导（IDE + ext4，2026-08 回填）

L1 在 L0 基础上增加：`CONFIG_BLOCK`、`CONFIG_PCI`、libata
（`CONFIG_ATA` + `CONFIG_ATA_PIIX`，QEMU 与参考机型同为 Intel PIIX 系）、
`CONFIG_BLK_DEV_SD`、`CONFIG_EXT4_FS`。分区表支持由 `CONFIG_BLOCK` 带入
`CONFIG_MSDOS_PARTITION`。配置档案：`kernel/configs/6.1.182-L1.config`、
`6.18.44-L1.config`。

### 构建与内存

QEMU 6.2 `-cpu pentium -m 24`，`console=ttyS0,115200`，`-kernel` + `-initrd`
冒烟（同一份 initramfs）：

| vintage | bzImage（XZ） | 内核可用内存（`Memory:` 行） | 内核明细 | 备注 |
|---|---|---|---|---|
| 6.1.182 | 1,221,120 B（1.16 MiB） | 19,620 K / 24,056 K | code 1880K, rwdata 630K, rodata 412K, init 212K, bss 248K, reserved 4436K | ata_piix 识别硬盘，启动到 shell |
| 6.18.44 | 1,303,040 B（1.24 MiB） | 19,152 K / 24,056 K | code 2035K, rwdata 637K, rodata 440K, init 240K, bss 208K, reserved 4616K | 同上 |

- L1 年代红利：**468 K**（6.1 比 6.18 多 468 K 可用内存），仍远低于 D10
  的 2 MiB 阈值；D10 继续倾向 6.18。
- bzImage 较 L0 增量：6.1 +421,888 B；6.18 +438,272 B。两树仍 < 2.5 MiB。

### IDE 磁盘 + ext4 root 验证（无 initramfs）

构造 64 MiB 磁盘镜像：`sfdisk` 建 DOS 分区表（一个 Linux 分区），
`mkfs.ext4 -d` 灌入 BusyBox rootfs，并用 `debugfs` 补 `/dev/console`
字符设备（宿主非 root 无法 `mknod`/`mount -o loop`，用 `debugfs` 绕过）。

启动参数：

```
qemu-system-i386 -m 24 -cpu pentium \
  -kernel kernel/src/linux-6.18/arch/x86/boot/bzImage \
  -drive file=/tmp/l1-disk.img,if=ide,format=raw \
  -nographic -no-reboot \
  -append 'console=ttyS0,115200 panic=-1 root=/dev/sda1 rootfstype=ext4 init=/bin/sh'
```

- 6.1.182：`Memory: 19732K/24056K available`；`EXT4-fs (sda1): mounted
  filesystem with ordered data mode`；`Run /bin/sh as init process`，落到
  BusyBox ash。
- 6.18.44：`Memory: 19264K/24056K available`；`EXT4-fs (sda1): mounted
  filesystem ... ro with ordered data mode`；同样落到 ash。
- 两个 vintage 均成功：`sda: sda1`（DOS 分区表解析正常）→ ext4 root 挂载
  → BusyBox 作为 PID 1。IDE + ext4 内核路径在 QEMU 上打通。

### syslinux 引导验证（2026-08 通过）

宿主无 root 无法 `mount -o loop`，改用两段式绕过：
1. 用 `mkfs.vfat` + `syslinux --install` 在独立 FAT 镜像上安装 SYSLINUX
   6.04（Ubuntu jammy 包直接 `dpkg-deb -x` 解包使用，不需要 root），
   `mcopy` 写入 `bzImage` 与 `syslinux.cfg`；
2. 把该 FAT 镜像 `dd` 到磁盘镜像的 FAT 分区偏移处，`mbr.bin` 写入磁盘
   前 440 字节，ext4 rootfs 镜像 `dd` 到 Linux 分区偏移处。

分区布局：`/dev/sda1` FAT16（bootable，SYSLINUX），`/dev/sda2` ext4 root。
`syslinux.cfg`：`SERIAL 0 115200`，`APPEND root=/dev/sda2 rootfstype=ext4
init=/bin/sh console=ttyS0,115200 panic=-1`。

QEMU `-boot c -drive file=<96 MiB 磁盘镜像>,if=ide,format=raw`（**不传
`-kernel`/`-initrd`**），两个 vintage 均成功：

| vintage | SeaBIOS → SYSLINUX | 内核 | root 挂载 | 结果 |
|---|---|---|---|---|
| 6.1.182 | `Loading /bzImage... ok` | `Linux version 6.1.182 ...` | `EXT4-fs (sda2): mounted ...` | BusyBox ash 作为 PID 1 |
| 6.18.44 | 同上 | `Linux version 6.18.44 ...` | `EXT4-fs (sda2): mounted ... ro` | 同上 |

至此 L1 存储/引导链在 QEMU 全链路打通：**BIOS → MBR → SYSLINUX →
bzImage → libata/IDE → DOS 分区 → ext4 root → BusyBox PID 1**。

### 模块化与内存对照（6.18.44，2026-08）

在 L1 基础上仅追加 `CONFIG_MODULES=y`（驱动仍全内置，不实际加载模块）：

| 配置 | bzImage | `Memory:` 行（`-kernel` + initramfs） | 差 |
|---|---|---|---|
| L1 全内置 | 1,303,040 B | 19,152 K / 24,056 K | 基线 |
| L1 + `CONFIG_MODULES` | 1,356,288 B | 19,008 K / 24,056 K | bzImage +52 KiB；用户态可用 **少 144 K** |

结论：在硬件固定、所需驱动全集已知且全都会用到的前提下，模块化不会省
内存，反而先亏掉模块加载器/符号表/重定位等基础设施（本实验约 144 K 用户
态内存 + 52 KiB 镜像）。这也支持设计文档 §3.2 "驱动全内置、禁用模块加载
器" 的决策；仅当未来出现多种互斥硬件变体、按需加载省下的驱动常驻明显
大于 144 K 时才值得重新评估。

## L2 外设（2026-08 起只做 6.18）

策略更新：L0/L1 已量化 6.1 与 6.18 的差距（年代红利 420 K / 468 K，均远
低于 2 MiB 阈值）。**L2 起先只做 6.18**：6.18 能开就先全流程跑通，6.1
暂时冻结在 L1；若后续 6.18 在外设层遇到无法接受的成本，再回退补做 6.1。

配置档案：`kernel/configs/6.18.44-L2.config`（基于 L1 增加）：
- 16 位 PCMCIA：`PCCARD`、`PCMCIA`、`I82365`（参考机型为 i82365 兼容
  ISA 桥；`I82365` 依赖 `ISA`，故补开 `ISA`）；
- 网络：`NET` + `NETDEVICES` + `ETHERNET`；8390 家族 `NE2000`（ISA）、
  `NE2K_PCI`（PCI，QEMU 可测）、`PCMCIA_PCNET`（PCMCIA，留待 86Box/真机）；
- VGA fb：`FB` + `FB_VESA` + `FB_VGA16`。

### 构建与 QEMU 冒烟（仅 6.18.44）

- bzImage：1,548,800 B（1.48 MiB），仍 < 2.5 MiB；较 L1 +245,760 B。
- `-kernel` + initramfs：`Memory: 18580K/24056K available`
  （code 2479K, rwdata 650K, rodata 540K, init 248K, bss 216K,
  reserved 5188K）。

QEMU 验证（`-cpu pentium -m 24`，串口控制台）：
- `-nic model=ne2k_pci`：`ne2k-pci 0000:00:03.0 eth0: RealTek
  RTL-8029(AS) found at 0xc000, IRQ 11` —— PCI NE2000 驱动正常。
- `-netdev user,id=n1 -device ne2k_isa,netdev=n1`：
  `ne ne.0 eth0: NE2000 found at 0x300, using IRQ 9`；同时
  `Intel ISA PCIC probe:` 出现（i82365 驱动完成 probe，QEMU 无该设备）。
- VGA：`Console: colour VGA+ 80x25`，`vgaarb` 正常；`FB_VESA`/`FB_VGA16`
  已编入内核，但 `-kernel -nographic` 路径下无 VESA BIOS，未出现 `fb0`。
  fb 实绑留待 syslinux/VESA 或 86Box 验证。
- syslinux 全链路复测通过：`-boot c` 不传 `-kernel`/`-initrd`，
  SYSLINUX 加载 1.48 MiB 的 L2 bzImage，ext4 root 挂载成功，
  `Memory: 18692K/24056K available`（无 initrd），BusyBox 落到 ash。

## 备注

- 构建用宿主机 gcc -m32 multilib（`ARCH=i386`），M0 交叉工具链就绪后迁移；
- 本机 gcc 是指向 ccache 的符号链接时，bwrap 等只读 `/run/user/...` 环境需
  `CCACHE_DISABLE=1`（或指定可写 `CCACHE_DIR`），否则 `make syncconfig`
  会因 ccache 临时目录只读失败；
- 6.18 注意：其 Kconfig 仍有 `M486`（7.x 才移除），两个 vintage 均可配
  Pentium Classic（`M586TSC`）——D10 实验统一用 `M586TSC`，贴参考机型。
