#!/bin/sh
# 组装 ThinkPad 770ED 的 rootfs（build/rootfs-770ed）。
#
# 与 scripts/build-rootfs.sh（M2，24 MiB 档）的差别：
#   1) 带上 /lib/modules（本风味有 110 个模块：CardBus/无线/声卡/猫/HID）
#   2) BusyBox applet 软链按 `busybox --list` 自动生成，不手写清单
#   3) 多 mdev/热插拔脚本、modprobe.d 调参、hwcheck 自检
#   4) 三个 s6 服务：console getty / serial getty / udhcpc
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}
BB_BIN=$ROOT/busybox/src/busybox-1.38.0/busybox
S6_ROOT=${M2_INSTALL_DIR:-$ROOT/build/m2root}
MODROOT=${MODROOT:-$ROOT/build/modroot-770ed}
TMPL=$ROOT/rootfs-770ed
PASSWORD=${ROOT_PASSWORD_HASH:-!}

[ -x "$BB_BIN" ] || { echo "build BusyBox first: scripts/build-core-770ed.sh" >&2; exit 1; }
[ -x "$S6_ROOT/usr/bin/s6-svscan" ] || { echo "build s6 first: scripts/build-s6.sh" >&2; exit 1; }
set -- "$MODROOT"/lib/modules/*/
[ -d "$1" ] || { echo "build modules first: scripts/build-core-770ed.sh" >&2; exit 1; }
case "$PASSWORD" in
  *:*) echo "ROOT_PASSWORD_HASH must not contain ':'" >&2; exit 1 ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/dev" "$DEST/proc" "$DEST/root" "$DEST/sbin" \
  "$DEST/sys" "$DEST/tmp" "$DEST/usr/bin" "$DEST/usr/sbin" \
  "$DEST/etc/s6" "$DEST/etc/modprobe.d" "$DEST/lib/modules" "$DEST/var/log"
chmod 0700 "$DEST/root"
chmod 1777 "$DEST/tmp"

cp "$BB_BIN" "$DEST/bin/busybox"
chmod 0755 "$DEST/bin/busybox"

# applet 软链：以二进制自己报告的 applet 表为准，避免"配了 applet 但
# 名字对不上 → applet not found"这类静默偏差。`[` 不在表里，ash 内建提供。
for applet in $("$BB_BIN" --list); do
  case "$applet" in
    '['|linuxrc) continue ;;
  esac
  ln -sf busybox "$DEST/bin/$applet"
done
# BusyBox 的 applet 按调用名分派，但 init/getty 之类的惯例位置仍是 /sbin。
# 注意：不要给 init 建软链——下面的 cp 会把模板 init 写穿到这个软链上，
# 结果 /bin/busybox 变成 shell 脚本、/bin/sh 递归解析，内核报
# "Run /sbin/init as init process … failed (error -40)"（ELOOP）。
for applet in halt poweroff reboot mkswap swapoff swapon modprobe depmod \
              insmod rmmod lsmod hwclock; do
  ln -sf ../bin/busybox "$DEST/sbin/$applet"
done

cp -a "$S6_ROOT/usr/." "$DEST/usr/"
cp -a "$MODROOT"/lib/modules/* "$DEST/lib/modules/"

# 模板（先删掉同名软链：cp 默认跟随软链，会写到 /bin/busybox 上）
rm -f "$DEST/sbin/init" "$DEST/sbin/hotplug"
cp "$TMPL/sbin/init" "$DEST/sbin/init"
cp "$TMPL/sbin/hotplug" "$DEST/sbin/hotplug"
cp "$TMPL/usr/sbin/hwcheck" "$DEST/usr/sbin/hwcheck"
for svc in getty-console getty-serial udhcpc; do
  mkdir -p "$DEST/etc/s6/$svc"
  cp "$TMPL/etc/s6/$svc/run" "$DEST/etc/s6/$svc/run"
done
cp "$TMPL/etc/securetty" "$DEST/etc/securetty"
cp "$TMPL/etc/mdev.conf" "$DEST/etc/mdev.conf"
cp "$TMPL"/etc/modprobe.d/*.conf "$DEST/etc/modprobe.d/"
cp "$ROOT/rootfs/etc/udhcpc.script" "$DEST/etc/udhcpc.script"
chmod 0755 "$DEST/sbin/init" "$DEST/sbin/hotplug" "$DEST/usr/sbin/hwcheck" \
  "$DEST/etc/s6/"*/run "$DEST/etc/udhcpc.script"

# 账号与文件系统
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$DEST/etc/passwd"
printf 'root:x:0:\n' > "$DEST/etc/group"
printf 'root:%s:19000:0:99999:7:::\n' "$PASSWORD" > "$DEST/etc/shadow"
chmod 0644 "$DEST/etc/passwd" "$DEST/etc/group" "$DEST/etc/securetty" "$DEST/etc/mdev.conf"
chmod 0600 "$DEST/etc/shadow"
printf 'constellation\n' > "$DEST/etc/hostname"
printf '/dev/sda2 / ext4 rw,relatime 0 1\nproc /proc proc defaults 0 0\nsysfs /sys sysfs defaults 0 0\ndevtmpfs /dev devtmpfs mode=0755 0 0\n' > "$DEST/etc/fstab"

# udev 缺席时的惯例：/dev/fd 等由 devtmpfs 提供；/var/log 留空目录。

echo "770ED rootfs written: $DEST"
echo "  modules: $(find "$DEST/lib/modules" -name '*.ko' | wc -l) 个"
echo "  size   : $(du -sh "$DEST" | cut -f1)"
if [ "$PASSWORD" = '!' ]; then
  echo "root login is locked; set ROOT_PASSWORD_HASH=\$(openssl passwd -6 'pw') when building to enable login"
fi
