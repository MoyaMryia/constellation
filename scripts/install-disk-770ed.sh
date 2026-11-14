#!/bin/sh
# 把 build/constellation-770ed.img 写进一块真实介质（CF 卡或 2.5" 硬盘），
# 可选扩容根分区、可选换成 grub4dos 引导。
#
#   sudo scripts/install-disk-770ed.sh /dev/sdX            # GRUB2（镜像自带）
#   sudo scripts/install-disk-770ed.sh /dev/sdX --grub4dos # 改用 grub4dos
#   FORCE=1 ...                                            # 跳过交互确认
#
# 安全措施（写盘会清空整块介质，所以宁可啰嗦）：
#   * 必须是**整块设备**（不是分区）、且不是根设备、没挂载、没 swap、
#     没被 device-mapper/loop 占用；
#   * 打印型号/容量，要你手打介质路径确认；
#   * 目标容量小于镜像时拒绝（除非 ALLOW_SHRINK=1）。
#
# 扩容：镜像默认按 3800 MiB 做（4 GB 的 CF 卡厂标是十进制），若目标更大，
# 脚本会把根分区（p3，无 swap 时是 p2）扩到介质末尾并 resize2fs。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
IMAGE=${IMAGE:-$ROOT/build/constellation-770ed.img}
G4D_DIR=${G4D_DIR:-$ROOT/build/grub4dos}
SWAP_MIB=${SWAP_MIB:-256}
[ "$SWAP_MIB" -gt 0 ] && ROOT_PART=3 || ROOT_PART=2

die () { echo "install-disk: $*" >&2; exit 1; }

[ $# -ge 1 ] || die "用法：$0 /dev/sdX [--grub4dos]"
DEV=$1; shift
WANT_G4D=0
for arg in "$@"; do
  case "$arg" in
    --grub4dos) WANT_G4D=1 ;;
    *) die "未知参数：$arg" ;;
  esac
done

[ -f "$IMAGE" ] || die "找不到镜像：$IMAGE（先跑 scripts/mkimage-770ed.sh）"
[ -b "$DEV" ] || die "$DEV 不是块设备"
[ "$(id -u)" = 0 ] || die "需要 root（写裸盘、resize2fs）"

# ---- 安全检查 ----
DEVNAME=$(basename "$DEV")
[ -e "/sys/class/block/$DEVNAME/partition" ] && die "$DEV 是分区，不是整块磁盘"
case "$DEVNAME" in
  loop*|ram*|zram*|sr*|md*|dm-*) die "$DEV 不是可用于系统的磁盘" ;;
esac
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null || echo "")
case "$ROOTSRC" in
  "$DEV"|"$DEV"p*|"$DEV"[0-9]*) die "$DEV 上有根文件系统，拒绝操作" ;;
esac
if findmnt -rno TARGET "$DEV" >/dev/null 2>&1; then
  die "$DEV 上有挂载点（先 umount）"
fi
if grep -q "^$DEV" /proc/swaps 2>/dev/null; then
  die "$DEV 正在做 swap（先 swapoff）"
fi
[ -e "/sys/class/block/$DEVNAME/holders" ] && [ -n "$(ls -A "/sys/class/block/$DEVNAME/holders" 2>/dev/null)" ] && \
  die "$DEV 被 device-mapper 之类占用"

IMG_SIZE=$(stat -c%s "$IMAGE")
DEV_SIZE=$(blockdev --getsize64 "$DEV")
MODEL=$(cat "/sys/class/block/$DEVNAME/device/model" 2>/dev/null || echo "?")
echo "install-disk: 目标 $DEV  ($MODEL, $(($DEV_SIZE / 1000000)) MB)"
echo "install-disk: 镜像 $IMAGE  ($(($IMG_SIZE / 1000000)) MB)"
if [ "$DEV_SIZE" -lt "$IMG_SIZE" ]; then
  [ "${ALLOW_SHRINK:-0}" = 1 ] || die "目标比镜像小，写不下（要强行试试就 ALLOW_SHRINK=1）"
  echo "install-disk: 警告：目标小于镜像，ALLOW_SHRINK=1 已放行" >&2
fi

if [ "${FORCE:-0}" != 1 ]; then
  printf 'install-disk: 会清空 %s 上的全部数据。确认请输入介质路径（%s）：' "$DEV" "$DEV"
  read -r answer
  [ "$answer" = "$DEV" ] || die "输入不匹配，已取消"
fi

# ---- 1) 写镜像 ----
echo "install-disk: 写入镜像……"
dd if="$IMAGE" of="$DEV" bs=4M conv=fsync status=progress
sync

# ---- 2) 扩根分区到介质末尾 ----
DEV_SECTORS=$(blockdev --getsz "$DEV")
ROOT_START=$(sfdisk -d "$DEV" | awk -v p="$DEV$ROOT_PART" '$1==p{print $4}' | tr -d ,)
ROOT_SIZE=$(sfdisk -d "$DEV" | awk -v p="$DEV$ROOT_PART" '$1==p{print $6}' | tr -d ,)
if [ -n "$ROOT_START" ] && [ -n "$ROOT_SIZE" ]; then
  WANT_SIZE=$((DEV_SECTORS - ROOT_START - 2048))   # 末尾留 1 MiB 余量
  if [ "$WANT_SIZE" -gt "$ROOT_SIZE" ]; then
    echo "install-disk: 根分区 p$ROOT_PART 扩容 $ROOT_SIZE -> $WANT_SIZE 扇区"
    # 注意：这里**不能**写 `*`（bootable）。DOS/BIOS 只认一个活动分区，
    # 两个分区都标 active 时老 BIOS 会拒绝启动；活动标志留在 p1 上。
    sfdisk --force --no-reread -N "$ROOT_PART" "$DEV" <<EOF
$ROOT_START, $WANT_SIZE, 83
EOF
    partprobe "$DEV" 2>/dev/null || blockdev --rereadpt "$DEV" 2>/dev/null || true
    sleep 1
    ROOT_DEV="$DEV$ROOT_PART"
    [ -b "$ROOT_DEV" ] || ROOT_DEV="$DEV"p"$ROOT_PART"
    if [ -b "$ROOT_DEV" ]; then
      e2fsck -f -y "$ROOT_DEV" || true
      resize2fs "$ROOT_DEV"
    else
      echo "install-disk: 没看到 $ROOT_DEV（内核还没重读分区表）；" \
           "重启后手动跑： resize2fs /dev/<根分区>" >&2
    fi
  fi
fi

# ---- 3) 可选：换成 grub4dos 引导 ----
if [ "$WANT_G4D" = 1 ]; then
  [ -f "$G4D_DIR/grldr.mbr" ] || die "缺少 $G4D_DIR/grldr.mbr（先跑 scripts/build-grub4dos.sh）"
  echo "install-disk: 安装 grub4dos 到 MBR"
  pt=$(mktemp)
  dd if="$DEV" of="$pt" bs=1 skip=446 count=66 status=none
  dd if="$G4D_DIR/grldr.mbr" of="$DEV" conv=notrunc status=none
  dd if="$pt" of="$DEV" bs=1 seek=446 conv=notrunc status=none
  rm -f "$pt"

  BOOT_DEV="$DEV"1
  [ -b "$BOOT_DEV" ] || BOOT_DEV="$DEV"p1
  if [ -b "$BOOT_DEV" ]; then
    mnt=$(mktemp -d)
    if mount -t vfat "$BOOT_DEV" "$mnt"; then
      cp "$G4D_DIR/grldr" "$mnt/grldr"
      sync
      umount "$mnt"
      echo "install-disk: grldr 已放到引导分区的根目录"
    else
      echo "install-disk: 挂不上 $BOOT_DEV，grldr 需要你自己拷进 FAT 分区根目录" >&2
    fi
    rmdir "$mnt" 2>/dev/null || true
  fi
fi

# ---- 4) 结果核对 ----
echo "install-disk: 完成。当前分区表："
sfdisk -d "$DEV" | sed -n '/^\/dev/p' | sed 's/^/    /'
echo "install-disk: 拔盘前确认："
echo "    - 引导器：$( [ "$WANT_G4D" = 1 ] && echo grub4dos || echo 'GRUB2（镜像自带）' )"
echo "    - 根分区：/dev/…$ROOT_PART；swap：$( [ "$SWAP_MIB" -gt 0 ] && echo "/dev/…2（首次启动 init 会 mkswap 并启用）" || echo 无 )"
echo "    - 首次启动后跑 hwcheck / x 验收，见 docs/thinkpad-770ed.md §7"
