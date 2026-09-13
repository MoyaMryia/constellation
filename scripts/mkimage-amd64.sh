#!/bin/sh
# Build a bootable Constellation x86_64 disk image **without root**.
#
# 布局与 scripts/deploy.sh 一致：DOS 分区表；p1 = FAT16 boot（内核 +
# grub.cfg），p2 = ext4 root（LABEL=root）。
#
# 为什么不用 deploy.sh：它依赖 losetup/mount，需要 root。
# 为什么不用 syslinux：syslinux 6.03 的 Linux 安装器在 euid != 0 时直接
#   退出（"This program needs root privilege"，且是 32 位二进制，fakeroot
#   的 LD_PRELOAD 也不适用于该 class），无法在无特权环境装到镜像里。
# 改用 GRUB 的手工安装法，全程只操作镜像文件：
#   grub-mkimage      产出 core.img（限制模块使其 < 1 MiB，放得进 MBR 与
#                     p1 之间 2048 扇区的空隙）
#   grub-bios-setup   把 boot.img 写 LBA0、core.img 写嵌入区（保留分区表）
#   mformat/mcopy     独立造 FAT 镜像再整块 dd 到 p1（避开 mtools 偏移坑）
#   mke2fs -E offset  在偏移处建 ext4 并直接灌入 rootfs（无需挂载）
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BZIMAGE=${BZIMAGE:-$ROOT/build/amd64/bzImage}
ROOTFS=${ROOTFS:-$ROOT/build/rootfs-amd64}
GRUB_DIR=${GRUB_DIR:-/usr/lib/grub/i386-pc}
OUT=${IMAGE:-$ROOT/build/amd64/constellation-x61.img}
DISK_SIZE=${DISK_SIZE:-512M}
BOOT_SIZE_MIB=${BOOT_SIZE_MIB:-32}
ROOT_SPEC=${ROOT_SPEC:-LABEL=root}
KERNEL_CMDLINE=${KERNEL_CMDLINE:-"root=/dev/sda2 rootfstype=ext4 init=/sbin/init console=tty0 console=ttyS0,115200"}

WORK=$(mktemp -d /tmp/constellation-mkimage.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

die () { echo "mkimage: $*" >&2; exit 1; }

[ -f "$BZIMAGE" ] || die "找不到内核：$BZIMAGE"
[ -d "$ROOTFS" ] || die "找不到 rootfs：$ROOTFS"
[ -f "$GRUB_DIR/boot.img" ] || die "缺少 GRUB i386-pc 模块目录：$GRUB_DIR"
for c in sfdisk mformat mcopy dd mke2fs truncate grub-mkimage; do
  command -v "$c" >/dev/null 2>&1 || die "缺少宿主工具：$c"
done

# ---- 1) 分区表 ----
rm -f "$OUT"
truncate -s "$DISK_SIZE" "$OUT"
sfdisk --quiet "$OUT" <<EOF
label: dos
unit: sectors
2048, $((BOOT_SIZE_MIB * 2048)), 0e, *
, , 83, -
EOF
P2_START=$(sfdisk --dump "$OUT" | awk '$1=="'"$OUT"'2"{print $4}' | tr -d ,)
[ -n "$P2_START" ] || die "无法解析 p2 起始扇区"
P1_OFF=$((2048 * 512))
P2_OFF=$((P2_START * 512))
echo "mkimage: p1@${P1_OFF}B(FAT16 ${BOOT_SIZE_MIB}MiB) p2@${P2_OFF}B(ext4)"

# ---- 2) 独立 FAT 引导分区 ----
BOOTIMG=$WORK/boot.img
mformat -i "$BOOTIMG" -C -v BOOT -T $((BOOT_SIZE_MIB * 2048)) ::
mcopy -i "$BOOTIMG" "$BZIMAGE" ::/bzImage
cat > "$WORK/grub.cfg" <<EOF
set timeout=3
set default=0
# vga= 已被现代内核废弃（会被告知"unknown parameter"并透传给用户空间），
# 改由 GRUB 自己设 VBE 模式并通过 screen_info 传给内核，vesafb 据此绑定。
set gfxpayload=1024x768x16
menuentry "Constellation x86_64 (ThinkPad X61)" {
  set root=(hd0,msdos1)
  linux /bzImage $KERNEL_CMDLINE
}
EOF
mcopy -i "$BOOTIMG" "$WORK/grub.cfg" ::/grub.cfg
dd if="$BOOTIMG" of="$OUT" bs=512 seek=$((P1_OFF / 512)) conv=notrunc status=none

# ---- 3) 装 GRUB 引导代码（手工布局，保留分区表）----
# grub-bios-setup 只接受真实块设备（"DEVICE must be an OS device"），对普通
# 文件会去猜宿主根设备而失败。改用 GRUB 2 的经典布局：boot.img 位于 LBA0、
# core.img 紧接 LBA1（首扇区自带块表，故直接拼接即可），再把分区表 66 字节
# （偏移 446..511）原样写回——boot.img 在该区域是空的，不写回会丢分区表。
grub-mkimage -O i386-pc -d "$GRUB_DIR" -o "$WORK/core.img" \
  -p '(hd0,msdos1)' \
  biosdisk part_msdos fat ext2 normal linux configfile search vbe
cp "$GRUB_DIR/boot.img" "$WORK/boot.img"
dd if="$OUT" of="$WORK/pt.bin" bs=1 skip=446 count=66 status=none
cat "$WORK/boot.img" "$WORK/core.img" > "$WORK/hdr.bin"
dd if="$WORK/hdr.bin" of="$OUT" conv=notrunc status=none
dd if="$WORK/pt.bin" of="$OUT" bs=1 seek=446 conv=notrunc status=none

# ---- 4) ext4 root（免挂载灌入） ----
mke2fs -q -F -t ext4 -L root -E offset="$P2_OFF" -d "$ROOTFS" "$OUT"

echo "mkimage: 完成 $OUT"
echo "  表观 $(stat -c%s "$OUT") 字节，实际占用 $(du -h "$OUT" | cut -f1)"
echo "  分区表校验："
sfdisk --dump "$OUT" | sed -n '/^\/.*img[12] :/p' | sed 's/^/    /'
