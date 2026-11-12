# M2 最小系统笔记

目标：musl + s6 + apk + 基础仓库（~30 包），硬盘安装形态可用，出 T0 实测需求表。

## 当前进度（2026-08）

- [x] 内核 6.18.44 L4（含 FILE_LOCKING、COMPAT_32BIT_TIME）
- [x] musl i486 交叉工具链（`toolchain/musl-i486`，静态 libc）
- [x] BusyBox 1.38.0 静态 i486（init/getty/login/modutils/swap 工具）
- [x] s6 全家桶：skalibs 2.15.1.0 + execline 2.9.9.2 + s6 2.15.1.0 + s6-rc 0.7.0.0（静态 i486，`build/m2root/usr`）
- [x] syslinux 硬盘启动：FAT boot + ext4 root，`/sbin/init` 挂载 proc/sysfs/devtmpfs 后 exec `s6-svscan /etc/s6`
- [x] QEMU 冒烟：`constellation login:` 出现在串口
- [x] M2 rootfs 模板与组装入口：`rootfs/` + `scripts/build-rootfs.sh`
- [x] IPv4 + BusyBox ip/udhcpc 配置（真机 DHCP 待 M3 验收）
- [ ] apk-tools 移植（下一步）
- [ ] 基础软件仓库 ~30 包
- [ ] T0 实测需求表

## s6 构建

见 `scripts/build-s6.sh`。要点：
- 用 `toolchain/musl-i486/bin/i486-linux-musl-gcc` 交叉编译；
- skarnet configure 必须提供交叉 sysdeps：
  `--with-sysdep-devurandom=yes --with-sysdep-posixspawnearlyreturn=no
  --with-sysdep-procselfexe=/proc/self/exe --with-sysdep-selectinfinite=yes`；
- `--enable-static-libc` 产出完全静态 i486 可执行文件；
- 需要 `i486-linux-musl-ar/ranlib/strip` 包装脚本（已在工具链 bin 中）。

## rootfs 布局（build/rootfs-m2）

```text
/bin/busybox + applet symlinks
/sbin/init            # 挂载 proc/sysfs/devtmpfs、remount rw、exec s6-svscan
/usr/bin/s6-*         # s6/s6-rc 静态工具
/usr/lib/             # 静态库（可裁剪）
/lib/modules/6.18.44  # 内核模块（从 build/modroot 拷贝）
/etc/s6/getty/run     # exec /bin/getty -L ttyS0 115200 vt100
/etc/s6/getty/supervise/
/etc/passwd           # root 默认锁定；测试登录需显式传 ROOT_PASSWORD_HASH
```

## 内核侧踩坑（L4 补开）

- s6-svscan 需要 `CONFIG_FILE_LOCKING`，否则报
  `another instance of s6-svscan is already running on the same directory`。
- s6-svscan 的 `iopause` 走 ppoll；32 位内核需开 `CONFIG_COMPAT_32BIT_TIME`，
  否则 `unable to iopause: Function not implemented`。

## 下一步

- apk-tools 已开始（build/apk-src v3.0.7，meson 1.2 装于 build/pip-meson）；
  zlib 1.2.11 / mbedtls 2.28 / openssl 3.0.2 静态依赖已装入 build/crossdeps，
  源码已 patch mbedtls 分支与 crypto_mbedtls.c 的 2.x 兼容问题。
  剩余阻塞：libfetch 的 TLS/链接（网络非当前重点，暂缓）。
- 部署脚本 `scripts/deploy.sh`：在 Linux 宿主上直接把 rootfs、模块、内核、
  syslinux 部署到目标磁盘（块设备或镜像文件），无需先拼磁盘镜像。脚本只使用
  宿主可信安装的 syslinux，并拒绝已挂载/swap/holder/已绑定 loop 的目标；新版
  安全检查仍待 root 环境全链路复测。磁盘部署不纳入当前核心正确性验收。
