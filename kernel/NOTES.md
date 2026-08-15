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
串口/init/devtmpfs/proc/sysfs，CPU 均为 Pentium Classic（M586TSC）。

| vintage | 层级 | bzImage | 用户态可用内存 @24M | 内核明细 | 备注 |
|---|---|---|---|---|---|
| 6.1.182 | L0 | 0.76 MiB（799,232 B，默认压缩） | **20,700 K / 24,056 K** | code 1178K, rwdata 561K, rodata 248K, init 184K, bss 244K, reserved 3356K | 启动正常，panic 仅为无 init（预期） |
| 6.18.44 | L0 | 0.82 MiB（864,768 B，默认压缩） | **20,280 K / 24,056 K** | code 1324K, rwdata 556K, rodata 272K, init 192K, bss 204K, reserved 3496K | 同上 |

**L0 年代红利：420 K（6.1 比 6.18 多出 420K 用户态可用内存）**——远低于
D10 的 2 MiB 阈值。若 L1–L4 数据不反转，D10 倾向 **6.18**（上游维护窗口
多约 2 年）。bzImage 两者均远低于 2.5 MiB 目标（尚未换 XZ，换了更小）。

### 过程记录

- 6.1：`make tinyconfig` 的默认 CPU 选择即兼容 Pentium，直接可建；
- 6.18：tinyconfig 默认 `M686`，`scripts/config --enable M586TSC` 无效
  （Kconfig choice 需先 `--disable M686`），症状为 bzImage 启动即拒绝
  （"requires an i686 CPU"）——修复后正常。此坑已记录，后续层级配置
  注意 choice 类符号的改法；
- 两个树均在 16 线程宿主机上 ~2 分钟完成 L0 构建，迭代成本可忽略。

## 备注

- 构建用宿主机 gcc -m32 multilib（`ARCH=i386`），M0 交叉工具链就绪后迁移；
- 6.18 注意：其 Kconfig 仍有 `M486`（7.x 才移除），两个 vintage 均可配
  Pentium Classic（`M586TSC`）——D10 实验统一用 `M586TSC`，贴参考机型。
