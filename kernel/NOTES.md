# 内核裁剪研究笔记（M1，6.18.44）

目标：从最小配置起步构建面向 Pentium/i486 的极简 LTS 内核，实测体积与内存。
2026-08 起**只做 6.18.44**；6.1 已从仓库移除（早期对比数据：L0 年代红利
420 K、L1 年代红利 468 K，均低于 2 MiB 阈值，保留在 git 历史中）。

## 验收目标（设计文档 §3.2）

- bzImage（XZ 压缩）≤ 2.5 MiB
- 启动后内核常驻 ≤ 8 MiB @ 24 MiB 机型

## 源码

- 版本：6.18.44（上游 EOL 2028-12）
- 源码树：`kernel/src/linux-6.18`（tarball 不删，归档策略兼容）

## 方法论

1. **起点用 `tinyconfig`**（`make tinyconfig`）：从近乎为空开始**加法**，
   而非从 defconfig 做减法——加法过程天然产出"每一项为什么存在"的记录；
2. 按功能层逐组开启并记录增量（每层构建一次，量尺寸）：
   - L0 可引导：串口控制台、无驱动（QEMU `-kernel` 直通启动即验证）；
   - L1 参考机型存储/引导：IDE/libata、ext4、syslinux 可引导；
   - L2 参考机型外设：16 位 PCMCIA、NE2000（`pcnet_cs`/8390）、VGA fb；
   - L3 内存机制：zram（LZ4）、swap 支持；
   - L4 用户空间契约：s6/BusyBox 所需（devtmpfs、proc/sysfs、
     必需的 namespace/cgroup 子集——以"init 能起、getty 能开"为验收）；
3. 测量：
   - 镜像尺寸：`ls -l arch/x86/boot/bzImage`；
   - 常驻内存：QEMU `-m 24` 启动后立即读 `/proc/meminfo` 的
     MemTotal/MemFree（initramfs 里静态 BusyBox 直接报数）；
   - 86Box（Pentium 133 精确模拟）留作最终确认，QEMU（`-cpu pentium`）
     用于快速迭代。

## 配置存档

`kernel/configs/` 下按 `6.18.44-Lx.config` 命名提交 git，每层附增量说明
（提交信息即裁剪日志）。6.1 配置已移除。

## 实测数据

环境：QEMU 6.2 `-cpu pentium -m 24`，串口控制台，CPU 为 Pentium Classic
（`M586TSC`）。bzImage 压缩为 **XZ**（`CONFIG_KERNEL_XZ`）。

### L0 可引导

L0 = tinyconfig + 串口/init/devtmpfs/proc/sysfs/BINFMT_SCRIPT。
无 initramfs 时 `Memory: 20280K/24056K available`
（code 1325K, rwdata 556K, rodata 272K, init 192K, bss 204K,
reserved 3496K）；bzImage 864,768 B（0.82 MiB，XZ）。
panic 仅为无 init（预期）。

过程坑：6.18 tinyconfig 默认 `M686`，`scripts/config --enable M586TSC`
无效（Kconfig choice 需先 `--disable M686`），症状为 bzImage 启动即拒绝
（"requires an i686 CPU"）。后续改 choice 类符号注意。

### M1 可引导核心（initramfs 启动）

musl i486 静态 BusyBox 1.38.0 作为 initramfs（glibc 静态 i386 在 Pentium
上因 i686 基线含 CMOV 会 `trap invalid opcode`，必须 i486 基线 libc，见
`busybox/NOTES.md`）。`-kernel` + initramfs 启动到 shell：

| bzImage | `Memory:` 行 | MemTotal | MemFree |
|---|---|---|---|
| 864,768 B（0.82 MiB） | 20,168 K / 24,056 K | 20,752 kB | 18,676 kB |

### L1 存储/引导（IDE + ext4 + syslinux）

L1 在 L0 上增加：`BLOCK`、`PCI`、libata（`ATA` + `ATA_PIIX`）、
`BLK_DEV_SD`、`EXT4_FS`（DOS 分区随 BLOCK 带入）。并保留模块加载器：
`CONFIG_MODULES` + `CONFIG_MODULE_UNLOAD`。

| 配置 | bzImage | `Memory:` 行（带 initramfs） |
|---|---|---|
| L1 全内置（无 MODULES） | 1,303,040 B（1.24 MiB） | 19,152 K / 24,056 K |
| L1 + MODULES | 1,356,288 B（1.29 MiB） | 19,008 K / 24,056 K |

模块基础设施成本：约 144 K 用户态内存 + 52 KiB bzImage，在 24 MiB 预算内
可接受。**决策：保留模块加载器，驱动默认内置。**

IDE 磁盘 + ext4 root 验证（无 initramfs）：
`-drive file=磁盘镜像,if=ide` + `root=/dev/sda1 rootfstype=ext4 init=/bin/sh`
成功：`sda: sda1` → `EXT4-fs (sda1): mounted` → BusyBox 作为 PID 1。
宿主非 root 无法 `mount -o loop`，用 `debugfs` 补 `/dev/console`。

syslinux 全链路验证通过（`-boot c`，不传 `-kernel`/`-initrd`）：
**BIOS → MBR → SYSLINUX → bzImage → libata/IDE → DOS 分区 → ext4 root →
BusyBox PID 1**。SYSLINUX 6.04 通过 Ubuntu jammy 包 `dpkg-deb -x` 解包
使用；FAT 分区镜像安装 SYSLINUX 后 `dd` 进分区，`mbr.bin` 写磁盘前 440
字节。

### L2 外设（6.18.44，驱动按需做模块）

L2 在 L1 上增加：`ISA`、`PCCARD`/`PCMCIA`/`I82365`（16 位 PCMCIA，
参考机型 i82365 兼容 ISA 桥）；`NET` + `NETDEVICES` + `ETHERNET` +
8390 家族；`FB` + `FB_VESA` + `FB_VGA16`。

**模块策略落地**：非启动必需驱动改为 `m`：
- `PCCARD`/`PCMCIA`/`I82365` = m
- `NE2000`（ISA）/`NE2K_PCI`（PCI）/`PCMCIA_PCNET`（PCMCIA）= m
- `FB_VGA16` = m（`FB_VESA` 是 bool，只能 y/n，保留 y）

启动必需仍内置：`ATA_PIIX`、`BLK_DEV_SD`、`EXT4_FS`。

| 配置 | bzImage | `Memory:` 行（带模块测试 initramfs） |
|---|---|---|
| L2 + MODULES，驱动=m | 1,577,472 B（1.50 MiB） | 18,480 K / 24,056 K |

syslinux 全链路复测：加载 1.50 MiB 的 L2 bzImage，
`Memory: 18604K/24056K available`（无 initrd），ext4 root 挂载成功。

QEMU 模块加载验证：
- 测试 initramfs 放入 `8390.ko` + `ne2k-pci.ko`；
- `insmod /lib/modules/.../8390.ko` 再 `insmod .../ne2k-pci.ko` 后，
  `ne2k-pci ... eth0: RealTek RTL-8029(AS) found ...`，`lsmod` 显示
  `ne2k_pci` 与 `8390` 已加载。
- `modprobe ne2k-pci`（BusyBox modprobe-small，`CONFIG_DEFAULT_MODULES_DIR`
  需设为 `/lib/modules`）可用，但首次会打 `Unknown symbol` 日志后自动补装
  依赖并成功；生产环境建议先 `depmod` 或按依赖顺序 `insmod`。
- ISA NE2000 模块 `ne.ko` 与 PCMCIA `pcnet_cs.ko` 已构建，留待真机/86Box。

模块构建与安装：
```
make ARCH=i386 -j16 modules
make ARCH=i386 INSTALL_MOD_PATH=$PWD/../../build/modroot modules_install
```
安装后布局：`build/modroot/lib/modules/6.18.44/kernel/drivers/...`
（含 `modules.dep`/`modules.alias` 等；目录不入库，镜像生成时装入 rootfs
的 `/lib/modules/6.18.44`）。依赖示例：
`ne2k-pci.ko -> 8390.ko`；`pcnet_cs.ko -> pcmcia.ko, pcmcia_core.ko,
8390.ko`。

VGA：`Console: colour VGA+ 80x25`，`vgaarb` 正常；`FB_VESA`/`FB_VGA16`
已编入/构建为模块，但 `-kernel -nographic` 路径无 VESA BIOS，未出现
`fb0`。fb 实绑留待 syslinux/VESA 或 86Box。

## L3 内存机制（zram + swap，2026-08 回填）

L3 在 L2 上增加：`CONFIG_ZRAM=y`、`CONFIG_ZRAM_BACKEND_LZ4=y`、
`CONFIG_ZRAM_DEF_COMP_LZ4=y`（默认压缩算法 lz4）。`CONFIG_SWAP` 在 L2
已开。配置档案：`kernel/configs/6.18.44-L3.config`。

- bzImage：1,589,760 B（1.52 MiB），仍 < 2.5 MiB；较 L2 +12,288 B。
- `-kernel` + initramfs：`Memory: 18460K/24056K available`
  （code 2467K, rwdata 644K, rodata 676K, init 244K, bss 212K,
  reserved 5308K）。

QEMU 验证（`-cpu pentium -m 24`，串口控制台）：
```
echo 8388608 > /sys/block/zram0/disksize
mkswap /dev/zram0
swapon /dev/zram0
free
cat /proc/swaps
```
- `zram0: detected capacity change from 0 to 16384`；
- `Setting up swapspace version 1, size = 8384512 bytes`；
- `Adding 8188k swap on /dev/zram0`；`free` 显示 `Swap: 8188 0 8188`；
- `/proc/swaps`：`/dev/zram0 partition 8188 0 -2`。
- BusyBox 侧同步开启 `MKSWAP`/`SWAPON`/`SWAPOFF`/`FREE`，initramfs
  符号链接加入对应 applet。

zram 作为 T0 档内存机制的验收路径打通；接下来 L4 用户空间契约
（s6/BusyBox 所需内核接口）。

## 备注

- 构建用宿主机 gcc -m32 multilib（`ARCH=i386`），M0 交叉工具链就绪后迁移；
- 本机 gcc 是指向 ccache 的符号链接时，bwrap 等只读 `/run/user/...` 环境需
  `CCACHE_DISABLE=1`（或指定可写 `CCACHE_DIR`），否则 `make syncconfig`
  会因 ccache 临时目录只读失败；
- 6.18 Kconfig 仍有 `M486`（7.x 才移除），统一用 `M586TSC`（Pentium
  Classic），贴参考机型。
