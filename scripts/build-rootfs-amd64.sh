#!/bin/sh
# Assemble the x86_64 (ThinkPad X61) rootfs from tracked templates + built artifacts.
#
# 与 scripts/build-rootfs.sh 的差别：
#   - 产物在 build/rootfs-amd64，模板在 rootfs-amd64/；
#   - 不拷贝 /lib/modules：x86_64 风味 CONFIG_MODULES=n，驱动全部内置
#     （见 kernel/configs/6.18.44-x61-amd64.fragment）；
#   - 多两个 getty 服务（tty1 = X61 本地屏，ttyS0 = QEMU 验收通道）
#     与一个 udhcpc 服务（e1000e 有线网）。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=${M2_ROOTFS:-$ROOT/build/rootfs-amd64}
TMPL=$ROOT/rootfs-amd64
BB_BIN=$ROOT/busybox/src/busybox-1.38.0/busybox
S6_ROOT=${M2_INSTALL_DIR:-$ROOT/build/m2root-amd64}
PASSWORD=${ROOT_PASSWORD_HASH:-!}

[ -x "$BB_BIN" ] || { echo "build BusyBox first: scripts/build-core-amd64.sh" >&2; exit 1; }
[ -x "$S6_ROOT/usr/bin/s6-svscan" ] || { echo "build s6 first: scripts/build-s6-amd64.sh" >&2; exit 1; }
case "$PASSWORD" in
  *:*) echo "ROOT_PASSWORD_HASH must not contain ':'" >&2; exit 1 ;;
esac

rm -rf "$DEST"
mkdir -p "$DEST/bin" "$DEST/dev" "$DEST/etc/s6" "$DEST/proc" \
  "$DEST/root" "$DEST/sbin" "$DEST/sys" "$DEST/tmp" "$DEST/usr"
chmod 0700 "$DEST/root"
chmod 1777 "$DEST/tmp"

cp "$BB_BIN" "$DEST/bin/busybox"
# applet 软链。比 i486 版（仅 initramfs 冒烟所需）显著加宽：X61 目标的
# 验收要求基础系统自洽完整（docs/design.md §5.1 D11），对应 fragment 见
# busybox/configs/busybox-1.38.0-amd64.fragment。
for applet in \
  awk basename bzip2 cat chmod chown clear cp cut date dd df diff dirname dmesg \
  du echo env expr find free getty grep gunzip gzip halt head hexdump hostname id \
  ifconfig insmod ip kill killall ln login ls lsmod md5sum mkdir mknod mktemp \
  mkswap modprobe more mount mountpoint mv nc netstat nohup nslookup od passwd \
  pidof ping poweroff ps pwd readlink realpath reboot rm rmdir rmmod route sed \
  seq sh sha256sum sleep sort stat su swapoff swapon sync tail tar telnet test top \
  touch tr udhcpc umount uname uniq unxz uptime vi watch wc wget which whoami \
  xargs xz yes; do
  ln -s busybox "$DEST/bin/$applet"
done
# 注意：不要为 `[` 建软链——BusyBox 的 applet 表里没有 `[` 这个名字，
# 软链会得到 "applet not found"。脚本里的 `[ ... ]` 由 ash 内建提供
# （CONFIG_ASH_TEST，见 busybox/configs/busybox-1.38.0-amd64.fragment）。

cp -a "$S6_ROOT/usr/." "$DEST/usr/"

# 模板：init + s6 服务 + DHCP 钩子
cp "$TMPL/sbin/init" "$DEST/sbin/init"
for svc in getty-console getty-serial udhcpc; do
  mkdir -p "$DEST/etc/s6/$svc"
  cp "$TMPL/etc/s6/$svc/run" "$DEST/etc/s6/$svc/run"
  chmod 0755 "$DEST/etc/s6/$svc/run"
done
cp "$ROOT/rootfs/etc/udhcpc.script" "$DEST/etc/udhcpc.script"
mkdir -p "$DEST/usr/share/udhcpc"
cp "$ROOT/rootfs/etc/udhcpc.script" "$DEST/usr/share/udhcpc/default.script"
cp "$TMPL/etc/securetty" "$DEST/etc/securetty"
chmod 0755 "$DEST/sbin/init" "$DEST/etc/udhcpc.script"

# apk-tools（可选）：构建产物存在就装入，并写好最小配置。
# 默认仓库指向 Alpine x86_64（同为 musl/x86_64，格式兼容），
# url_backend=wget 需要 http（BusyBox wget 无 TLS）。
APK_BIN=${APK_BIN:-$ROOT/build/apk-amd64/usr/bin/apk}
if [ -x "$APK_BIN" ]; then
  mkdir -p "$DEST/sbin" "$DEST/etc/apk/keys"
  cp "$APK_BIN" "$DEST/sbin/apk"
  chmod 0755 "$DEST/sbin/apk"
  printf 'x86_64\n' > "$DEST/etc/apk/arch"
  : > "$DEST/etc/apk/world"
  printf '%s\n' "${APK_REPOSITORIES:-/var/apk/repo}" \
    > "$DEST/etc/apk/repositories"
  # 可选：把自建示例仓库放进镜像（仅用于验收；正式镜像不带）
  if [ -n "$APK_DEMO_REPO" ] && [ -d "$APK_DEMO_REPO" ]; then
    mkdir -p "$DEST/var/apk/repo"
    cp -a "$APK_DEMO_REPO/." "$DEST/var/apk/repo/"
    echo "embedded apk repo: $APK_DEMO_REPO -> /var/apk/repo"
  fi
else
  echo "note: apk not built, skipping (run scripts/build-apk-amd64.sh)" >&2
fi

printf 'root:x:0:0:root:/root:/bin/sh\n' > "$DEST/etc/passwd"
printf 'root:x:0:\n' > "$DEST/etc/group"
printf 'root:%s:19000:0:99999:7:::\n' "$PASSWORD" > "$DEST/etc/shadow"
chmod 0644 "$DEST/etc/passwd" "$DEST/etc/group" "$DEST/etc/securetty"
chmod 0600 "$DEST/etc/shadow"
printf 'constellation\n' > "$DEST/etc/hostname"
printf '/dev/root / ext4 ro,relatime 0 1\nproc /proc proc defaults 0 0\nsysfs /sys sysfs defaults 0 0\n' > "$DEST/etc/fstab"

echo "x86_64 rootfs written: $DEST"
if [ "$PASSWORD" = '!' ]; then
  echo "root login is locked; set ROOT_PASSWORD_HASH when building to enable login"
fi
