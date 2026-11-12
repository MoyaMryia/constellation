#!/bin/sh
# 产出可引导的 ThinkPad 770ED 镜像（免 root）。
#
# 布局（与 scripts/mkimage-amd64.sh 一致）：
#   LBA0..      MBR 引导代码（GRUB i386-pc boot.img + 嵌入的 core.img）
#   p1  FAT16   /bzImage、/grub.cfg、/grub/、以及给 grub4dos 用的 /menu.lst
#   p2  ext4    LABEL=root，rootfs（/sbin/init → s6-svscan）
#
# 为什么是 GRUB2 而不是 syslinux：syslinux 6.03 的 Linux 安装器要求
# euid==0 且是 32 位二进制，免 root 装不进镜像；GRUB2 的手工布局
# （boot.img + grub-mkimage 产出的 core.img + 原样写回分区表）全程只
# 操作镜像文件。
#
# 为什么同时放一份 menu.lst：770ED 这类机器上很多人习惯用 grub4dos。
# FAT 分区里预置 grldr 用的 menu.lst 与同一个 bzImage，用 bootlace/grubinst
# 把 grub4dos 装到 MBR 或分区引导扇区后即可直接引导，不必重做镜像。
# 详见 docs/thinkpad-770ed.md §4。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
KVER=${KVER:-6.6.162}
BZIMAGE=${BZIMAGE:-$ROOT/kernel/src/linux-$KVER/arch/x86/boot/bzImage}
ROOTFS=${ROOTFS:-$ROOT/build/rootfs-770ed}
GRUB_DIR=${GRUB_DIR:-/usr/lib/grub/i386-pc}
# GRUB4DOS=1：用 grub4dos（BIOS 版 0.4.6a）做引导器（需要先跑
# scripts/build-grub4dos.sh）。默认仍是 GRUB2。
GRUB4DOS=${GRUB4DOS:-0}
G4D_DIR=${G4D_DIR:-$ROOT/build/grub4dos}
OUT=${IMAGE:-$ROOT/build/constellation-770ed.img}
# 目标介质：4 GB 的 CF 卡厂标是十进制，实际只有 ~3.98e9 字节，所以默认
# 做 3800 MiB（3.98e9 B），避免"卡比镜像小一点点"。8.1 GB 硬盘用
# DISK_SIZE=7800M；更大的介质也行，写盘脚本会把根分区扩到满。
DISK_SIZE=${DISK_SIZE:-3800M}
BOOT_SIZE_MIB=${BOOT_SIZE_MIB:-32}
# swap 分区大小（MiB，0 = 不要）。63 MiB 内存的机器 + X 桌面，256 MiB
# 是比较舒服的量；CF 卡有写入寿命，别给太大。
SWAP_MIB=${SWAP_MIB:-256}
# 770ED 是 IDE（libata 之后统一叫 sdX）：系统盘 = sda。
#   有 swap 时布局： p1 boot(FAT16) / p2 swap / p3 root  ← 根放最后，方便扩容
#   无 swap 时布局： p1 boot(FAT16) / p2 root
if [ "${SWAP_MIB:-256}" -gt 0 ]; then ROOT_PART=3; else ROOT_PART=2; fi
# cswap= 让 init 明确知道哪个分区是 swap（不靠猜：布局改成 root=p2 时
# 猜错就会把根分区 mkswap 掉）。
SWAP_OPT=
if [ "$SWAP_MIB" -gt 0 ]; then SWAP_OPT=" cswap=/dev/sda2"; fi
KERNEL_CMDLINE=${KERNEL_CMDLINE:-"root=/dev/sda$ROOT_PART rootfstype=ext4 init=/sbin/init console=tty0 console=ttyS0,115200n8 earlycon=uart8250,io,0x3f8,115200n8$SWAP_OPT"}
# gfxpayload 只影响 GRUB 自己画的菜单。本风味**不开 vesafb**（否则会和
# tridentfb 抢同一块显卡，控制台滞留在 vesafb 上），所以默认让 GRUB 保持
# 文本模式，进内核后再由 tridentfb 切到 1024x768 帧缓冲控制台。
GFXPAYLOAD=${GFXPAYLOAD:-text}

WORK=$(mktemp -d /tmp/constellation-770ed-mkimage.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

die () { echo "mkimage-770ed: $*" >&2; exit 1; }

[ -f "$BZIMAGE" ] || die "找不到内核：$BZIMAGE（先跑 scripts/build-core-770ed.sh）"
[ -d "$ROOTFS" ] || die "找不到 rootfs：$ROOTFS（先跑 scripts/build-rootfs-770ed.sh）"
[ -f "$GRUB_DIR/boot.img" ] || die "缺少 GRUB i386-pc 模块目录：$GRUB_DIR"
for c in sfdisk mformat mcopy dd mke2fs truncate grub-mkimage; do
  command -v "$c" >/dev/null 2>&1 || die "缺少宿主工具：$c"
done

# ---- 1) 分区表 ----
rm -f "$OUT"
truncate -s "$DISK_SIZE" "$OUT"
if [ "$SWAP_MIB" -gt 0 ]; then
  sfdisk --quiet "$OUT" <<EOF
label: dos
unit: sectors
2048, $((BOOT_SIZE_MIB * 2048)), 0e, *
, $((SWAP_MIB * 2048)), 82, -
, , 83, -
EOF
else
  sfdisk --quiet "$OUT" <<EOF
label: dos
unit: sectors
2048, $((BOOT_SIZE_MIB * 2048)), 0e, *
, , 83, -
EOF
fi
P2_START=$(sfdisk --dump "$OUT" | awk -v p="$OUT$ROOT_PART" '$1==p{print $4}' | tr -d ,)
[ -n "$P2_START" ] || die "无法解析根分区起始扇区"
P1_OFF=$((2048 * 512))
P2_OFF=$((P2_START * 512))
echo "mkimage-770ed: p1@${P1_OFF}B(FAT16 ${BOOT_SIZE_MIB}MiB) 根分区 p${ROOT_PART}@${P2_OFF}B(ext4) swap=${SWAP_MIB}MiB"

# ---- 2) 独立 FAT 引导分区 ----
BOOTIMG=$WORK/boot.img
mformat -i "$BOOTIMG" -C -v BOOT -T $((BOOT_SIZE_MIB * 2048)) ::
mcopy -i "$BOOTIMG" "$BZIMAGE" ::/bzImage
cat > "$WORK/grub.cfg" <<EOF
set timeout=3
set default=0
set gfxpayload=$GFXPAYLOAD
menuentry "Constellation OS (ThinkPad 770ED)" {
  set root=(hd0,msdos1)
  linux /bzImage $KERNEL_CMDLINE
}
EOF
cat > "$WORK/menu.lst" <<EOF
# grub4dos 菜单（grldr 读这个文件）。
# 内核与 GRUB2 用的是同一个 /bzImage，参数也一致——换引导器不影响系统。
timeout 3
default 0
title Constellation OS (ThinkPad 770ED)
  kernel /bzImage $KERNEL_CMDLINE
EOF
mcopy -i "$BOOTIMG" "$WORK/grub.cfg" ::/grub.cfg
mcopy -i "$BOOTIMG" "$WORK/menu.lst" ::/menu.lst
if [ "$GRUB4DOS" = 1 ]; then
  [ -f "$G4D_DIR/grldr" ] || die "GRUB4DOS=1 但缺少 $G4D_DIR/grldr（先跑 scripts/build-grub4dos.sh）"
  mcopy -i "$BOOTIMG" "$G4D_DIR/grldr" ::/grldr
fi
dd if="$BOOTIMG" of="$OUT" bs=512 seek=$((P1_OFF / 512)) conv=notrunc status=none

# ---- 3) 装引导代码（保留分区表）----
if [ "$GRUB4DOS" = 1 ]; then
  # grub4dos：grldr.mbr（8 KiB = MBR + 紧随其后的引导代码）写到 LBA0，
  # 然后原样写回 66 字节分区表。grldr 本身在 FAT 分区根目录，menu.lst 同理。
  #
  # 顺序很重要：**必须先读出分区表再写引导代码**。先写再读，读到的是
  # grldr.mbr 里那 66 字节的 0，会把分区表清空 —— 症状正是 grub4dos 报
  # "Try (hd0): non-MS: skip" 四次然后 "Cannot find GRLDR"。
  dd if="$OUT" of="$WORK/pt.bin" bs=1 skip=446 count=66 status=none
  dd if="$G4D_DIR/grldr.mbr" of="$OUT" conv=notrunc status=none
  dd if="$WORK/pt.bin" of="$OUT" bs=1 seek=446 conv=notrunc status=none
  echo "mkimage-770ed: 引导器 = grub4dos（grldr.mbr @ LBA0，grldr 在 p1）"
else
grub-mkimage -O i386-pc -d "$GRUB_DIR" -o "$WORK/core.img" \
  -p '(hd0,msdos1)' \
  biosdisk part_msdos fat ext2 normal linux configfile search vbe
cp "$GRUB_DIR/boot.img" "$WORK/boot.img"
dd if="$OUT" of="$WORK/pt.bin" bs=1 skip=446 count=66 status=none
cat "$WORK/boot.img" "$WORK/core.img" > "$WORK/hdr.bin"
dd if="$WORK/hdr.bin" of="$OUT" conv=notrunc status=none
dd if="$WORK/pt.bin" of="$OUT" bs=1 seek=446 conv=notrunc status=none
echo "mkimage-770ed: 引导器 = GRUB2（boot.img + core.img）"
fi

# ---- 4) ext4 根分区（免挂载灌入） ----
mke2fs -q -F -t ext4 -L root -E offset="$P2_OFF" -d "$ROOTFS" "$OUT"

echo "mkimage-770ed: 完成 $OUT"
echo "  根 = /dev/sda$ROOT_PART；swap = $( [ "$SWAP_MIB" -gt 0 ] && echo "/dev/sda2（${SWAP_MIB}MiB，首次启动由 init 做 mkswap 并启用）" || echo "无" )"
echo "  表观 $(stat -c%s "$OUT") 字节，实际占用 $(du -h "$OUT" | cut -f1)"
sfdisk --dump "$OUT" | sed -n '/^\/.*img[12] :/p' | sed 's/^/    /'
