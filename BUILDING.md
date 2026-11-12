# 构建 Constellation OS

构建在 Linux x86_64 宿主上进行。宿主需要 GCC 的 32 位 multilib、GNU make、
binutils、curl、tar、xz、bzip2、cpio、gzip 和 Linux 内核构建依赖。

## 核心组件

```sh
./scripts/build-core.sh
```

该命令会下载并校验 Linux 6.18.44、BusyBox 1.38.0 和 musl 1.2.5，随后从
干净目录构建 i486 musl、BusyBox、Pentium 内核、模块和 M1 initramfs。
可通过 `JOBS` 调整并行度。

真 486 内核使用独立风味：

```sh
KERNEL_FLAVOR=legacy486 ./scripts/build-core.sh
```

该风味在 L4 配置上应用 `kernel/configs/6.18.44-legacy486.fragment`，并开启
486SX 所需的数学模拟。Pentium 是参考机型和默认风味。

## M2 Rootfs

```sh
./scripts/build-s6.sh
./scripts/build-rootfs.sh
```

默认 root 账户锁定，串口 getty 不允许登录。需要测试登录时，显式传入由
`openssl passwd -6` 等工具生成的 crypt 哈希：

```sh
ROOT_PASSWORD_HASH='$6$...' ./scripts/build-rootfs.sh
```

不要把明文密码或私有密码哈希提交到仓库。

## 后续磁盘部署

磁盘分区、Syslinux 安装和真实硬盘写入不属于当前核心构建验收。下面的入口只
在以后准备专用测试镜像/设备时使用，不能替代当前的 initramfs 和 QEMU 核心冒烟。

宿主必须通过可信包管理器安装 `syslinux` 和 `mbr.bin`，也可以用
`SYSLINUX_DIR` 指向包含两者的目录。脚本不会联网下载并执行宿主二进制。

先用镜像文件验证：

```sh
sudo ./scripts/deploy.sh build/constellation.img -f
```

写入块设备会清空整盘，必须额外传 `-f`。脚本会拒绝已挂载、用作 swap、
存在 device-mapper holder 或已绑定 loop 设备的目标。

## ThinkPad 770ED 风味

770ED 走独立的一套脚本（i686 内核 + 模块 + CardBus 驱动），用户空间仍是
上面那套 musl i486 / BusyBox / s6 产物：

```sh
JOBS=16 scripts/build-core-770ed.sh                 # 默认 Linux 6.6.162 LTS
KVER=6.18.44 JOBS=16 scripts/build-core-770ed.sh    # 可选：6.18.44（无 16 位无线）

H=$(openssl passwd -6 '密码')
ROOT_PASSWORD_HASH="$H" EXTRA_USERS="moyamryia:$H" scripts/build-rootfs-770ed.sh
scripts/mkimage-770ed.sh                            # 3800 MiB（4 GB CF 卡）
DISK_SIZE=7800M scripts/mkimage-770ed.sh            # 8.1 GB 硬盘
SWAP_MIB=0 scripts/mkimage-770ed.sh                 # 不要 swap 分区
GRUB4DOS=1 scripts/mkimage-770ed.sh                 # 用 grub4dos 引导
scripts/build-grub4dos.sh                           # 先编 grub4dos（源码构建）

sudo scripts/install-disk-770ed.sh /dev/sdX             # 写盘（含扩容/安全检查）
sudo scripts/install-disk-770ed.sh /dev/sdX --grub4dos  # 写盘并换 grub4dos
```

改内核配置后先重算完整配置（逐项核验 fragment 真的生效）：

```sh
KVER=6.6.162 scripts/genconfig-770ed.sh
```

镜像布局与 x86_64 线一致（DOS 分区表；p1 FAT16 放 bzImage/grub.cfg/
menu.lst，p2 ext4 是 root），引导器是 GRUB2 i386-pc；FAT 分区里同时预置了
grub4dos 的 `menu.lst`，装 grub4dos 后可直接引导。细节、驱动矩阵与踩坑
清单见 [docs/thinkpad-770ed.md](docs/thinkpad-770ed.md)。
