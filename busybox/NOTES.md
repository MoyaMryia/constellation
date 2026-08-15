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
   产物：`busybox`，ELF 32-bit i386 static stripped，约 237 KiB
   （2026-08 开模块/swap/getty/login 工具后）。
   坑：musl 上必须开 `CONFIG_LFS=y`，否则 BusyBox 的
   `BUG_off_t_size_is_misdetected` 编译期负数组报错。

## 配置档案

- `busybox/configs/busybox-1.38.0-M1.config` — 最小 M1 配置（static +
  ash + mount/umount + 基础工具 + `INSMOD`/`RMMOD`/`LSMOD`/
  `MODPROBE_SMALL`）。注意其中 `CONFIG_EXTRA_CFLAGS` 的
  `-isystem` 路径是本机绝对路径，换机后需改为对应 `build/hdrs-i386` 路径。
- `busybox/initramfs/init` — initramfs 的 `/init`：安装 applet 符号链接，
  挂载 proc/sysfs/devtmpfs，打印 meminfo，`exec /bin/sh`。
- `busybox/mkinitramfs.sh` — 生成 `build/initramfs.cpio.gz`；applet
  符号链接包含 `insmod`/`rmmod`/`lsmod`/`modprobe`。

## 实测

QEMU 6.2 `-cpu pentium -m 24`，`console=ttyS0,115200`：

- initramfs.cpio.gz：142,204 B
- BusyBox：242,900 B（无 CMOV/SSE 等 i686+ 指令；已带模块/swap/getty/login 工具）
- 6.18.44：`Memory: 20168K/24056K`，`MemTotal 20752 kB`，`MemFree 18676 kB`

6.18.44 成功落到 ash 提示符，输入回显正常（见 kernel/NOTES.md）。

### 直接以 BusyBox 为 PID 1 的冒烟测试（2026-08）

不经过 `/init` 脚本，直接让内核把 BusyBox 的 `sh` 符号链接作为 init 执行：

```
qemu-system-i386 -m 24 -cpu pentium \
  -kernel kernel/src/linux-6.18/arch/x86/boot/bzImage \
  -initrd build/initramfs.cpio.gz -nographic -no-reboot \
  -append 'console=ttyS0,115200 panic=-1 rdinit=/bin/sh'
```

- 6.18.44 成功：内核打印 `Run /bin/sh as init process`，
  BusyBox ash 作为 PID 1 输出提示符；手动执行
  `mount -t proc proc /proc`、`uname -a`、`poweroff -f` 均正常。
- 注意：`rdinit=/bin/sh` 会绕过 `initramfs/init`，proc/sysfs/devtmpfs
  不会自动挂载；完整启动仍走 `rdinit=/init`（默认）。
- `poweroff -f` 在 6.18 上提示 `Power off not available: System halted
  instead`（无 ACPI/PM 时预期行为），用 `halt -f` 或让 QEMU 超时结束即可。
