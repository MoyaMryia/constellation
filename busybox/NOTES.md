# BusyBox initramfs 研究笔记（M1）

M1 需要 BusyBox initramfs 在 24 MiB 启动到 shell。用户空间二进制基线为
**i486**（design.md §2.2），而宿主机的 32 位 glibc 静态库是 i686 基线
（含 `cmove`），在 `-cpu pentium`（P54C，无 CMOV/FXSR）上会
`trap invalid opcode`。因此 M1 原型直接构建 **musl i486** 静态 BusyBox。

## 构建方法

1. **i486 内核头**（供 BusyBox 引用 linux/ 头）：
   ```
   cd kernel/src/linux-6.18
   make ARCH=i386 CC=/usr/bin/gcc-11 HOSTCC=/usr/bin/gcc-11 \
       INSTALL_HDR_PATH=$PWD/../../build/hdrs-i386 headers_install
   ```
2. **musl 1.2.5**（源码 tarball 在 `toolchain/src/`，构建产物
   `toolchain/musl-i486/`，均不入库）：
   ```
   cd toolchain/src/musl-1.2.5
   CC=/usr/bin/gcc-11 CFLAGS="-m32 -march=i486 -Os -pipe -fomit-frame-pointer" \
   CROSS_COMPILE= AR=/usr/bin/ar RANLIB=/usr/bin/ranlib \
     ./configure --target=i486-linux-musl \
     --prefix=$PWD/../../musl-i486 --disable-shared
   make -j16 && make install
   ```
   注意：musl 的 `musl-gcc.specs` 会覆盖 link spec，需要补上
   `%{m32:-m elf_i386}` 与 `%{Wl,*}`（本仓库构建时已手动补丁，否则
   宿主机 gcc 链接 32 位目标时不会传 `-m elf_i386`，ld 会报
   `skipping incompatible libc.a`）。
3. **BusyBox 1.38.0**：
   ```
   cd busybox/src/busybox-1.38.0
   make HOSTCC=/usr/bin/gcc-11 allnoconfig
   # 以 configs/busybox-1.38.0-M1.config 为模板（已开 STATIC、LFS、
   # ash/mount/cat/... 最小集），或直接 cp 该 config 为 .config
   make HOSTCC=/usr/bin/gcc-11 CC=$PWD/../../../toolchain/musl-i486/bin/i486-linux-musl-gcc oldconfig
   make -j16 HOSTCC=/usr/bin/gcc-11 CC=$PWD/../../../toolchain/musl-i486/bin/i486-linux-musl-gcc
   ```
   产物：`busybox`，ELF 32-bit i386 static stripped，约 193 KiB。
   坑：musl 上必须开 `CONFIG_LFS=y`，否则 BusyBox 的
   `BUG_off_t_size_is_misdetected` 编译期负数组报错。

## 配置档案

- `busybox/configs/busybox-1.38.0-M1.config` — 最小 M1 配置（static +
  ash + mount/umount + 基础工具）。注意其中 `CONFIG_EXTRA_CFLAGS` 的
  `-isystem` 路径是本机绝对路径，换机后需改为对应 `build/hdrs-i386` 路径。
- `busybox/initramfs/init` — initramfs 的 `/init`：安装 applet 符号链接，
  挂载 proc/sysfs/devtmpfs，打印 meminfo，`exec /bin/sh`。
- `busybox/mkinitramfs.sh` — 生成 `build/initramfs.cpio.gz`。

## 实测

QEMU 6.2 `-cpu pentium -m 24`，`console=ttyS0,115200`：

- initramfs.cpio.gz：113,938 B
- BusyBox：197,844 B（无 CMOV/SSE 等 i686+ 指令）
- 6.18.44：`Memory: 20168K/24056K`，`MemTotal 20752 kB`，`MemFree 18676 kB`
- 6.1.182：`Memory: 20588K/24056K`，`MemTotal 20884 kB`，`MemFree 18672 kB`

两个 vintage 均成功落到 ash 提示符，输入回显正常（见 kernel/NOTES.md）。
