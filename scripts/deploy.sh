#!/bin/sh
# deploy.sh — 把 Constellation 系统部署到目标磁盘。
#
# 用法（需 root）：
#   sudo ./scripts/deploy.sh /dev/sdX          # 部署到块设备（真机/硬盘）
#   sudo ./scripts/deploy.sh disk.img          # 部署到磁盘镜像文件（QEMU/86Box）
#
# 输入可覆盖（环境变量）：
#   BZIMAGE    内核镜像，默认 kernel/src/linux-6.18/arch/x86/boot/bzImage
#   ROOTFS     rootfs 目录，默认 build/rootfs-m2
#   MODROOT    模块安装根（make modules_install 产物），默认 build/modroot
#   SYSLINUX_DIR  宿主 syslinux 文件目录（含 syslinux 和 mbr.bin），默认探测宿主安装
#   BOOT_SIZE  boot 分区大小，默认 32M
#   DISK_SIZE  新镜像文件大小，默认 1024M
#   ROOT_SPEC  内核 root= 参数，默认 LABEL=root
#
# 产出布局：DOS 分区表；p1 = FAT16 boot（syslinux + bzImage + syslinux.cfg），
# p2 = ext4 root（rootfs + 模块）。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

BZIMAGE=${BZIMAGE:-$ROOT/kernel/src/linux-6.18/arch/x86/boot/bzImage}
ROOTFS=${ROOTFS:-$ROOT/build/rootfs-m2}
MODROOT=${MODROOT:-$ROOT/build/modroot}
BOOT_SIZE=${BOOT_SIZE:-32M}
DISK_SIZE=${DISK_SIZE:-1024M}
ROOT_SPEC=${ROOT_SPEC:-LABEL=root}

WORK=$(mktemp -d /tmp/constellation-deploy.XXXXXX)
MNT_BOOT=$WORK/mnt-boot
MNT_ROOT=$WORK/mnt-root
LOOP=""

die () { echo "deploy: $*" >&2; exit 1; }

cleanup () {
  umount "$MNT_ROOT" 2>/dev/null || true
  umount "$MNT_BOOT" 2>/dev/null || true
  if findmnt -Rno TARGET "$MNT_ROOT" 2>/dev/null | grep -q . || \
     findmnt -Rno TARGET "$MNT_BOOT" 2>/dev/null | grep -q .; then
    echo "deploy: 挂载点仍在使用，保留工作目录以避免删除目标数据：$WORK" >&2
    return
  fi
  if [ -n "$LOOP" ]; then
    losetup -d "$LOOP" 2>/dev/null || {
      echo "deploy: 无法释放 loop 设备，保留工作目录：$WORK" >&2
      return
    }
    LOOP=""
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

[ "$(id -u)" = 0 ] || die "需要 root（分区/挂载）"
[ -f "$BZIMAGE" ] || die "找不到内核镜像：$BZIMAGE"
[ -d "$ROOTFS" ] || die "找不到 rootfs：$ROOTFS"
[ -d "$MODROOT/lib/modules" ] || die "找不到模块：$MODROOT/lib/modules"

for command in basename blockdev cp dd findmnt grep id lsblk losetup mkfs.ext4 \
  mkfs.vfat mount realpath sfdisk swapon sync truncate umount; do
  command -v "$command" >/dev/null 2>&1 || die "缺少宿主工具：$command"
done

TARGET=${1:-}
[ -n "$TARGET" ] || die "用法：$0 <设备或镜像文件> [-f]"
[ "$#" -le 2 ] || die "用法：$0 <设备或镜像文件> [-f]"

# ---------- 输入解析 ----------
FORCE=""
[ "$2" = "-f" ] && FORCE=1

if [ -b "$TARGET" ]; then
  # 块设备：必须显式 -f；且整棵设备树不得正被使用。
  [ -n "$FORCE" ] || die "目标 $TARGET 是块设备，确认将覆盖其全部数据：加 -f"
  [ "$(lsblk -dnro TYPE "$TARGET")" = disk ] || die "目标不是整盘块设备：$TARGET"
  lsblk -nrpo MOUNTPOINTS "$TARGET" | grep -q '[^[:space:]]' && die "目标或其分区已挂载"
  for part in $(lsblk -nrpo NAME "$TARGET"); do
    swapon --noheadings --raw --show=NAME 2>/dev/null | grep -Fxq "$part" && die "$part 正用作 swap"
    for holder in "/sys/class/block/$(basename "$part")/holders/"*; do
      [ -e "$holder" ] && die "$part 正被 $(basename "$holder") 使用"
    done
  done
  DISK=$TARGET
else
  [ -e "$TARGET" ] || [ -n "$FORCE" ] || die "镜像 $TARGET 不存在，确认新建：加 -f"
  [ -e "$TARGET" ] && [ ! -f "$TARGET" ] && die "目标不是普通文件也不是块设备"
  if [ ! -e "$TARGET" ]; then
    truncate -s "$DISK_SIZE" "$TARGET"
  fi
  [ -z "$(losetup -j "$TARGET")" ] || die "镜像已绑定 loop 设备：$TARGET"
  LOOP=$(losetup -fP --show "$TARGET")
  DISK=$LOOP
fi

# 分区设备名（/dev/sda -> sda1；/dev/loop0 -> loop0p1）
case "$DISK" in
  *[0-9]) P1=${DISK}p1; P2=${DISK}p2 ;;
  *)      P1=${DISK}1;  P2=${DISK}2 ;;
esac

# ---------- syslinux 来源 ----------
SYSLINUX_BIN=""
MBR_BIN=""
if [ -n "$SYSLINUX_DIR" ]; then
  SYSLINUX_BIN=$SYSLINUX_DIR/syslinux
  MBR_BIN=$SYSLINUX_DIR/mbr.bin
elif command -v syslinux >/dev/null 2>&1; then
  SYSLINUX_BIN=$(command -v syslinux)
  for d in /usr/lib/syslinux/mbr/mbr.bin /usr/share/syslinux/mbr.bin /usr/lib/syslinux/mbr.bin; do
    [ -f "$d" ] && MBR_BIN=$d && break
  done
fi
if [ -z "$SYSLINUX_BIN" ] || [ -z "$MBR_BIN" ]; then
  die "宿主缺少可信的 syslinux/mbr.bin；请安装 syslinux，或设置 SYSLINUX_DIR"
fi
[ -x "$SYSLINUX_BIN" ] || die "找不到 syslinux 可执行文件：$SYSLINUX_BIN"
[ -f "$MBR_BIN" ] || die "找不到 mbr.bin：$MBR_BIN"

# ---------- 分区与格式化 ----------
echo "deploy: 分区 $DISK（p1=FAT16 boot $BOOT_SIZE，p2=ext4 root）"
sfdisk --wipe always --wipe-partitions always "$DISK" <<EOF
label: dos
unit: sectors
2048, $BOOT_SIZE, 0e, *
, , 83, -
EOF
udevadm settle 2>/dev/null || partprobe "$DISK" || true

mkfs.vfat -F 16 -n BOOT "$P1" >/dev/null
mkfs.ext4 -F -L root "$P2" >/dev/null
echo "deploy: 写入 mbr.bin（磁盘前 440 字节）"
dd if="$MBR_BIN" of="$DISK" bs=440 count=1 conv=notrunc status=none

# ---------- boot 分区：syslinux + 内核 ----------
echo "deploy: 安装 syslinux 引导器"
"$SYSLINUX_BIN" --install "$P1"
mkdir -p "$MNT_BOOT"
mount "$P1" "$MNT_BOOT"
cp "$BZIMAGE" "$MNT_BOOT/bzImage"
cat > "$MNT_BOOT/syslinux.cfg" <<EOF
DEFAULT linux
PROMPT 0
TIMEOUT 50
LABEL linux
  KERNEL bzImage
  APPEND root=$ROOT_SPEC rootfstype=ext4 init=/sbin/init console=tty0 console=ttyS0,115200
EOF

# ---------- root 分区：rootfs + 模块 ----------
mkdir -p "$MNT_ROOT"
mount "$P2" "$MNT_ROOT"
echo "deploy: 拷贝 rootfs（$ROOTFS）"
cp -a "$ROOTFS/." "$MNT_ROOT/"
# 模块以 modroot 为准覆盖（modroot 不含指向本机源码树的 build 符号链接）
MODULE_DEST=$(realpath -m "$MNT_ROOT/lib/modules")
case "$MODULE_DEST" in
  "$MNT_ROOT"/*) ;;
  *) die "rootfs 的 /lib/modules 逃逸目标挂载点：$MODULE_DEST" ;;
esac
rm -rf "$MODULE_DEST"
mkdir -p "$MODULE_DEST"
cp -a "$MODROOT/lib/modules/." "$MODULE_DEST/"

sync
umount "$MNT_ROOT"
umount "$MNT_BOOT"
if [ -n "$LOOP" ]; then
  losetup -d "$LOOP"
  LOOP=""
  echo "验证：qemu-system-i386 -m 24 -drive file=$TARGET,if=ide -boot c -nographic"
fi
trap - EXIT
rm -rf "$WORK"
echo "deploy: 完成。"
