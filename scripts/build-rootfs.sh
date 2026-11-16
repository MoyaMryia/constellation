#!/bin/sh
# Assemble the M2 rootfs from tracked templates and built artifacts.
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=${M2_ROOTFS:-$ROOT/build/rootfs-m2}
BB_BIN=$ROOT/busybox/src/busybox-1.38.0/busybox
S6_ROOT=${M2_INSTALL_DIR:-$ROOT/build/m2root}
MODROOT=${MODROOT:-$ROOT/build/modroot}
PASSWORD=${ROOT_PASSWORD_HASH:-!}

[ -x "$BB_BIN" ] || { echo "build BusyBox first: scripts/build-core.sh" >&2; exit 1; }
[ -x "$S6_ROOT/usr/bin/s6-svscan" ] || { echo "build s6 first: scripts/build-s6.sh" >&2; exit 1; }
[ -d "$MODROOT/lib/modules" ] || { echo "build kernel modules first: scripts/build-core.sh" >&2; exit 1; }
case "$PASSWORD" in
  *:*) echo "ROOT_PASSWORD_HASH must not contain ':'" >&2; exit 1 ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/dev" "$DEST/etc/s6/getty" "$DEST/proc" \
  "$DEST/root" "$DEST/sbin" "$DEST/sys" "$DEST/tmp" "$DEST/usr" \
  "$DEST/lib/modules"
chmod 0700 "$DEST/root"
chmod 1777 "$DEST/tmp"

cp "$BB_BIN" "$DEST/bin/busybox"
for applet in cat echo free getty halt hostname insmod ip login ls lsmod mkdir \
  mknod mkswap modprobe mount poweroff reboot rmmod sh sleep swapoff swapon \
  sync udhcpc umount uname; do
  ln -s busybox "$DEST/bin/$applet"
done
cp -a "$S6_ROOT/usr/." "$DEST/usr/"
cp -a "$MODROOT/lib/modules/." "$DEST/lib/modules/"
cp "$ROOT/rootfs/sbin/init" "$DEST/sbin/init"
cp "$ROOT/rootfs/etc/s6/getty/run" "$DEST/etc/s6/getty/run"
cp "$ROOT/rootfs/etc/udhcpc.script" "$DEST/etc/udhcpc.script"
mkdir -p "$DEST/usr/share/udhcpc"
cp "$ROOT/rootfs/etc/udhcpc.script" "$DEST/usr/share/udhcpc/default.script"
chmod 0755 "$DEST/sbin/init" "$DEST/etc/s6/getty/run" "$DEST/etc/udhcpc.script"
printf 'root:x:0:0:root:/root:/bin/sh\n' > "$DEST/etc/passwd"
printf 'root:x:0:\n' > "$DEST/etc/group"
printf 'root:%s:19000:0:99999:7:::\n' "$PASSWORD" > "$DEST/etc/shadow"
chmod 0644 "$DEST/etc/passwd" "$DEST/etc/group"
chmod 0600 "$DEST/etc/shadow"
printf 'constellation\n' > "$DEST/etc/hostname"

echo "M2 rootfs written: $DEST"
if [ "$PASSWORD" = '!' ]; then
  echo "root login is locked; set ROOT_PASSWORD_HASH to an explicit crypt hash when building to enable login"
fi
