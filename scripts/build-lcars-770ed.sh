#!/bin/sh
# 用 BasicLinux 3.5 LCARS 做一个能在 ThinkPad 770ED（PII 266 / 64 MiB）
# 上原生启动的 CF 卡镜像。
#
# BasicLinux 3.5 是「唯一能在 386 + 4 MB 上跑起来的 LiveCD」，内核是
# Linux 2.2.26。它自带三份按 CPU 编译的内核（见 livecd/docs/config.txt）：
#
#   zimage.4dx   CONFIG_M486      486DX
#   zimage.p1    CONFIG_M586TSC   Pentium（带 TSC）
#   zimage.p2    CONFIG_M686      **Pentium II —— 770ED 用这份**
#   bzimage.big  CONFIG_M386      通用大内核（模块齐全，配全套 .o）
#
# 上游的启动方式是 MS-DOS + LOADLIN；这里改成 grub4dos 直接引导 zimage.p2，
# root 用真实的 ext2 分区（而不是上游的 loop + FS.IMG 镜像），因此：
#   - 不需要 DOS、不需要 ramdisk，64 MiB 内存全给系统用
#   - 分区布局与 constellation-770ed.img 一致（p1 boot / p2 swap / p3 root）
#
# 用法：
#   sudo LCARS_SRC=~/Downloads/basiclinux-lcars scripts/build-lcars-770ed.sh
#   sudo LCARS_SRC=... DISK_SIZE=7800M OUT=build/bl-lcars-8g.img scripts/build-lcars-770ed.sh
#
# LCARS_SRC 指向 queenkjuul/basiclinux-lcars 的 clone（需要 livecd/ 与 rootfs/）。
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SRC=${LCARS_SRC:-$ROOT/vendor/basiclinux-lcars}
OUT=${OUT:-$ROOT/build/constellation-770ed-lcars.img}
DISK_SIZE=${DISK_SIZE:-3800M}
BOOT_MIB=${BOOT_MIB:-64}
SWAP_MIB=${SWAP_MIB:-256}
LABEL_BOOT=${LABEL_BOOT:-LCARS}
# 上游三份内核里挑哪一份；770ED = Pentium II → p2
LCARS_KERNEL=${LCARS_KERNEL:-zimage.p2}
# 额外做一个 ramdisk(loop FS.IMG) 启动项？需要 p1 上放 fs.img（默认不做）
WITH_FSIMG=${WITH_FSIMG:-0}
G4D_DIR=${G4D_DIR:-$ROOT/build/grub4dos}

die() { echo "build-lcars-770ed: $*" >&2; exit 1; }
say() { echo "==> $*"; }

[ "$(id -u)" -eq 0 ] || die "需要 root（要建 loop 文件系统、设文件属主、建设备节点）"

KERNEL_SRC=$SRC/livecd/kernels/$LCARS_KERNEL
INITFS=$SRC/livecd/baslin/INITFS.GZ
TREE=$SRC/rootfs
[ -f "$KERNEL_SRC" ] || die "找不到 $KERNEL_SRC（LCARS_SRC 指错了？）"
[ -d "$TREE" ] || die "找不到 $TREE（需要完整 clone，含 rootfs/）"
[ -f "$G4D_DIR/grldr" ] || die "缺少 $G4D_DIR/grldr（先跑 scripts/build-grub4dos.sh）"

WORK=$(mktemp -d "$ROOT/build/.lcars.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---- 1) 算分区边界 ----
TOTAL=$(( $(numfmt --from=iec "$DISK_SIZE") / 512 ))
BOOT_SECT=$(( BOOT_MIB * 2048 ))
SWAP_SECT=$(( SWAP_MIB * 2048 ))
# DOS 时代的几何约定（LCARS 这套本来就是 MS-DOS 血统）：
#   第一条磁道 63 扇区留给 MBR/引导代码 → p1 从 LBA 63 开始；
#   后续分区对齐到柱面（63 扇区/磁道 × 16 磁头 = 1008 扇区）。
SECT_PER_TRACK=63
HEADS=16
CYL=$(( SECT_PER_TRACK * HEADS ))
align_up () { echo $(( (($1 + CYL - 1) / CYL) * CYL )); }
BOOT_SECT=$(align_up "$BOOT_SECT")
P1_OFF=$SECT_PER_TRACK
P2_OFF=$(align_up $(( P1_OFF + BOOT_SECT )))
P3_OFF=$(align_up $(( P2_OFF + SWAP_SECT )))
P3_SECT=$(( TOTAL - P3_OFF - 2048 ))
[ "$P3_SECT" -gt 400000 ] || die "root 分区太小（DISK_SIZE=$DISK_SIZE）"

say "创建 $OUT（$DISK_SIZE）"
rm -f "$OUT"
truncate -s "$DISK_SIZE" "$OUT" 2>/dev/null || dd if=/dev/zero of="$OUT" bs=1M \
  count=$(( $(numfmt --from=iec "$DISK_SIZE") / 1048576 )) status=none

sfdisk "$OUT" >/dev/null <<EOF
label: dos
unit: sectors
start=$P1_OFF, size=$BOOT_SECT, type=6, bootable
start=$P2_OFF, size=$SWAP_SECT, type=82
start=$P3_OFF, size=$P3_SECT, type=83
EOF

# ---- 2) p1：FAT16 + grub4dos + 内核 ----
say "制作 p1（FAT16 ${BOOT_MIB}MiB）"
dd if=/dev/zero of="$WORK/boot.img" bs=512 count=$BOOT_SECT status=none
# hidden sectors = 分区起始 LBA（63），DOS 靠它算绝对扇区
mkfs.vfat -F 16 -n "$LABEL_BOOT" -h "$P1_OFF" "$WORK/boot.img" >/dev/null
mkdir -p "$WORK/baslin"
cp "$KERNEL_SRC" "$WORK/baslin/ZIMAGE"
cp "$INITFS" "$WORK/baslin/INITFS.GZ"
for k in zimage.p1 zimage.4dx bzimage.big; do
  [ -f "$SRC/livecd/kernels/$k" ] && cp "$SRC/livecd/kernels/$k" "$WORK/baslin/$k"
done
[ -f "$SRC/livecd/baslin/LOADLIN.EXE" ] && cp "$SRC/livecd/baslin/LOADLIN.EXE" "$WORK/baslin/"
[ -f "$SRC/livecd/baslin/BOOT.BAT" ] && cp "$SRC/livecd/baslin/BOOT.BAT" "$WORK/baslin/"

cat > "$WORK/menu.lst" <<EOF
# grub4dos menu: BasicLinux 3.5 LCARS, kernel = $LCARS_KERNEL (CONFIG_M686).
# root is a real ext2 partition (not the upstream loop + FS.IMG), so no initrd.
timeout 5
default 0

title BasicLinux 3.5 LCARS (ThinkPad 770ED, /dev/hda3)
  kernel /baslin/ZIMAGE root=/dev/hda3 rw

# NOTE: this 2.2.26 kernel was built without CONFIG_SERIAL_CONSOLE (hence the
# "Serial driver version 4.27 with no serial options enabled" line at boot), so
# console=ttyS0 does NOT send the kernel log to the serial port. /etc/inittab
# still starts a getty on ttyS0, so you do get a login shell there; getting the
# kernel log on serial needs a rebuilt 2.2 kernel.
title BasicLinux 3.5 LCARS (serial 115200 login shell; kernel log stays on VGA)
  kernel /baslin/ZIMAGE root=/dev/hda3 rw console=ttyS0,115200

title BasicLinux 3.5 LCARS (lowmem, for 4MB machines)
  kernel /baslin/ZIMAGE root=/dev/hda3 ro lowmem

title BasicLinux 3.5 LCARS (486 kernel zimage.4dx)
  kernel /baslin/zimage.4dx root=/dev/hda3 rw

title BasicLinux 3.5 LCARS (generic 386 kernel bzimage.big)
  kernel /baslin/bzimage.big root=/dev/hda3 rw
EOF

if [ "$WITH_FSIMG" = 1 ]; then
  cat >> "$WORK/menu.lst" <<'EOF'

title BasicLinux 3.5 LCARS (ramdisk + fs.img, upstream original)
  kernel /baslin/ZIMAGE root=/dev/ram0 rw initrd=/baslin/INITFS.GZ
EOF
fi

mmd -i "$WORK/boot.img" ::/baslin
mcopy -i "$WORK/boot.img" "$G4D_DIR/grldr" ::/grldr
mcopy -i "$WORK/boot.img" "$WORK/menu.lst" ::/menu.lst
if [ "$WITH_FSIMG" = 1 ]; then
  cat "$SRC"/livecd/baslin/fs.img* > "$WORK/baslin/fs.img" 2>/dev/null || true
  [ -s "$WORK/baslin/fs.img" ] || die "WITH_FSIMG=1 但 livecd/baslin/ 里没有 fs.img"
fi
for f in "$WORK"/baslin/*; do
  mcopy -i "$WORK/boot.img" "$f" "::/baslin/$(basename "$f")"
done
dd if="$WORK/boot.img" of="$OUT" bs=512 seek=$((P1_OFF)) conv=notrunc status=none

# ---- 3) 引导代码：grldr.mbr @ LBA0（先读分区表，再写）----
dd if="$OUT" of="$WORK/pt.bin" bs=1 skip=446 count=66 status=none
dd if="$G4D_DIR/grldr.mbr" of="$OUT" conv=notrunc status=none
dd if="$WORK/pt.bin" of="$OUT" bs=1 seek=446 conv=notrunc status=none
say "引导器 = grub4dos"

# ---- 4) p3：2.2 内核能吃下的 ext2，内容 = 上游 rootfs/ ----
# 2.2.26 不认识 ext3/ext4 的绝大多数特性（dir_index/filetype/extent/64bit…），
# 所以这里用 -O none 生成最朴素的 rev-0 ext2，块大小 1 KiB。
say "准备 root 树（$TREE）"
cp -a "$TREE" "$WORK/root"

# 4.1 串口 getty：BL3 的 inittab 只有 tty1..3，加一条 ttyS0 方便远程
if ! grep -q '^ttyS0::' "$WORK/root/etc/inittab"; then
  printf 'ttyS0::askfirst:-/bin/sh\n' >> "$WORK/root/etc/inittab"
fi

# 4.2 swap 放在 /dev/hda2（上游只认 swap.img 文件）
if ! grep -q 'hda2' "$WORK/root/etc/rc"; then
  python3 - "$WORK/root/etc/rc" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = "test $SWAPOFF || mount -t msdos /dev/hda1 /hda1"
add = ("# constellation: 真分区 swap（上游只认 swap.img 文件）。\n"
       "# 第一次开机 /dev/hda2 还没有 swap 签名，所以失败就 mkswap 再来。\n"
       "if test ! $SWAPOFF; then\n"
       "  swapon /dev/hda2 2>/dev/null || { mkswap /dev/hda2 && swapon /dev/hda2; }\n"
       "fi\n")
i = s.find(anchor)
s = s[:i] + add + s[i:] if i >= 0 else s + "\n" + add
open(p, 'w').write(s)
PY
fi

# 4.3 fstab
cat > "$WORK/root/etc/fstab" <<'EOF'
/dev/hda3  /      ext2  defaults        1 1
/dev/hda2  swap   swap  defaults        0 0
proc       /proc  proc  defaults        0 0
EOF
# 上游把 /etc/mtab 做成了 -> /proc/mounts 的软链；2.2 时代的 mount 不会去跟，
# 每次执行都报 "can't open /etc/mtab"。换成真的空文件（mount 会自己写）。
rm -f "$WORK/root/etc/mtab"
: > "$WORK/root/etc/mtab"
chmod 0644 "$WORK/root/etc/mtab"

# 4.3b 恢复可执行位：上游仓库里**所有文件都是 0644**（从一个没保留权限的
# 地方提交的，git ls-files 里 0 个 100755）。不修的话内核 exec /sbin/init 会
# 失败，症状是 "Kernel panic: No init found"。
say "恢复可执行位"
python3 - "$WORK/root" <<'PY'
import os, stat, sys
root = sys.argv[1]
fixed = 0
for base, dirs, names in os.walk(root):
    for n in names:
        p = os.path.join(base, n)
        if os.path.islink(p):
            continue
        try:
            st = os.stat(p)
        except OSError:
            continue
        if not stat.S_ISREG(st.st_mode):
            continue
        try:
            with open(p, 'rb') as f:
                magic = f.read(4)
        except OSError:
            continue
        # ELF 或脚本（#!）→ 补执行位
        if magic == b'\x7fELF' or magic[:2] == b'#!':
            os.chmod(p, st.st_mode | 0o111)
            fixed += 1
print(f"  补了 {fixed} 个可执行位")
PY
# /etc/rc、/linuxrc 之类没 #! 的老脚本也补上
chmod 0755 "$WORK/root/etc/rc" "$WORK/root/linuxrc" 2>/dev/null || true
for d in bin sbin usr/bin usr/sbin usr/X11R6/bin opt; do
  [ -d "$WORK/root/$d" ] && find "$WORK/root/$d" -type f -exec chmod a+x {} + 2>/dev/null || true
done

# 4.4 /dev 设备节点：git 不能存设备文件，上游 clone 下来的 rootfs/dev 是空的，
# 必须自己补（否则内核报 "unable to open an initial console" → "No init found"）。
mknode() { # mknode <path> <c|b> <major> <minor> [mode]
  rm -f "$WORK/root/dev/$1"
  mknod "$WORK/root/dev/$1" "$2" "$3" "$4"
  chmod "${5:-600}" "$WORK/root/dev/$1"
}
mkdir -p "$WORK/root/dev"
mknode console c 5 1 600
mknode null    c 1 3 666
mknode zero    c 1 5 666
mknode mem     c 1 1 640
mknode kmem    c 1 2 640
mknode port    c 1 4 640
mknode random  c 1 8 644
mknode urandom c 1 9 644
mknode tty     c 5 0 666
i=0; while [ $i -le 8 ]; do mknode "tty$i" c 4 "$i" 600; i=$((i+1)); done
mknode ttyS0 c 4 64 600
mknode ttyS1 c 4 65 600
mknode psaux c 10 1 600
mknode ptmx  c 5 2 666
mknode hda b 3 0 660; mknode hda1 b 3 1 660; mknode hda2 b 3 2 660
mknode hda3 b 3 3 660; mknode hda4 b 3 4 660
mknode hdb b 3 64 660; mknode hdc b 22 0 660; mknode hdd b 22 64 660
mknode fd0 b 2 0 660
mknode ram0 b 1 0 660; mknode ram1 b 1 1 660; mknode ram2 b 1 2 660
mknode loop0 b 7 0 660
# 上游把 mouse 指向串口鼠标；PS/2 触控板用 psaux，两个都留着
ln -sfn /dev/psaux "$WORK/root/dev/mouse"

# 4.4b 挂载点：上游 /etc/rc 会把 /dev/hda1 挂到 /hda1（找 swap.img），
# 上游 fstab 里还有 /dev/fd0 -> /fd。目录不存在的话 mount 会报错。
mkdir -p "$WORK/root/hda1" "$WORK/root/fd"

# 4.5 说明放在 /root
cat > "$WORK/root/root/README.constellation" <<'EOF'
This is BasicLinux 3.5 LCARS (kernel 2.2.26, CONFIG_M686 = the Pentium II
build). The CF-card image was assembled by Constellation's
scripts/build-lcars-770ed.sh.

Boot: grub4dos loads /baslin/ZIMAGE with root=/dev/hda3 (a real ext2 partition)
Serial: pick the menu entry that adds console=ttyS0,115200
Swap: /dev/hda2 (256 MiB), enabled by swapon in /etc/rc

The upstream ramdisk mode (loop + FS.IMG) is not enabled; rebuild with
WITH_FSIMG=1 and put fs.img into /baslin/ if you want it.

Caveats: 2.2.26 has no APM, no CardBus (yenta) and no USB 2.0; PCMCIA is 16-bit
only (the /etc/pcmcia + i82365 module set lives under /lib/modules/2.2.26).
EOF

mke2fs -q -F -t ext2 -b 1024 -I 128 -O none -L lcars -E offset=$((P3_OFF * 512)) \
  -d "$WORK/root" "$OUT"

say "完成 $OUT"
echo "  布局：p1 FAT16 ${BOOT_MIB}MiB(grub4dos+baslin) / p2 swap ${SWAP_MIB}MiB / p3 ext2(lcars)"
echo "  内核：$LCARS_KERNEL（CONFIG_M686）"
sfdisk --dump "$OUT" | sed -n 's/^\(.*img[0-9]*\) *: /\1: /p'
du -h "$OUT" | sed 's/^/  实际占用 /'
