#!/bin/sh
# 给 770ED 镜像编无线工具：wireless-tools（iwconfig/iwlist）+ wpa_supplicant。
#
# 为什么自己编：Alpine 的 x86 归档基线是 Pentium III（SSE），而 770ED 是
# Pentium II。镜像整体按"零 SSE 指令"审计（scripts/audit-sse-770ed.sh），
# 所以这两个也必须用本工程的 i486 musl 工具链编译。
#
# wpa_supplicant 用 wext 驱动 + internal TLS：
#   - nl80211 驱动要 libnl-3/libnl-genl，多一条依赖链，而内核已经开了
#     CONFIG_CFG80211_WEXT（cfg80211 兼容层），wext 足够 WPA/WPA2-PSK
#   - CONFIG_TLS=internal 免掉 OpenSSL，省 ~3 MB 和一堆 SSE 风险
#
# 用法：scripts/build-wireless-770ed.sh [rootfs-dir]
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}}" && pwd)
SRCROOT=${WIRELESS_SRC:-$ROOT/toolchain/src/wireless}
CC_WRAP=$ROOT/toolchain/musl-i486/bin/i486-linux-musl-gcc
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
CFLAGS_COMMON="-Os -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector"

# Linux UAPI 头（linux/wireless.h、linux/types.h...）：musl 自带的不含，直接用
# 本工程已经铺好的一份（build-xlibs 的 staging 里就有，和内核树对齐）。
UAPI=
for d in "$ROOT/build/xlibs-770ed/usr/include" "$ROOT/build/hdrs-i386/include"; do
  if [ -f "$d/linux/wireless.h" ]; then UAPI=$d; break; fi
done
[ -n "$UAPI" ] || { echo "缺少 Linux UAPI 头（先跑 scripts/build-core-770ed.sh）" >&2; exit 1; }

[ -x "$CC_WRAP" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }
mkdir -p "$SRCROOT"
PATH=$ROOT/toolchain/musl-i486/bin:$PATH
export PATH

fetch () {
  url=$1; file=$SRCROOT/${url##*/}
  if [ ! -s "$file" ]; then
    echo "wl: 下载 ${url##*/}" >&2
    curl -fsSL --retry 3 -o "$file.part" "$url" && mv "$file.part" "$file"
  fi
  echo "$file"
}

# ---- wireless-tools（iwconfig / iwlist）----
WLT=$(fetch "http://deb.debian.org/debian/pool/main/w/wireless-tools/wireless-tools_30~pre9.orig.tar.gz")
cd "$SRCROOT"
[ -d wireless_tools.30 ] || tar -xzf "$WLT"
if [ ! -x "$SRCROOT/wireless_tools.30/iwconfig" ]; then
  echo "wl: 编 wireless-tools"
  make -C wireless_tools.30 clean >/dev/null 2>&1 || true
  make -C wireless_tools.30 -j"$JOBS" CC=i486-linux-musl-gcc \
    CFLAGS="$CFLAGS_COMMON -I$UAPI" LDFLAGS="" BUILD_STATIC=0 \
    iwconfig iwlist iwgetid iwspy iwevent >/dev/null
fi

# ---- wpa_supplicant ----
WPA=$(fetch "https://w1.fi/releases/wpa_supplicant-2.10.tar.gz")
cd "$SRCROOT"
[ -d wpa_supplicant-2.10 ] || tar -xzf "$WPA"
if [ ! -x "$SRCROOT/wpa_supplicant-2.10/wpa_supplicant/wpa_supplicant" ]; then
  echo "wl: 编 wpa_supplicant（wext + internal TLS）"
  cd wpa_supplicant-2.10/wpa_supplicant
  # 从零写 .config，而不是 sed defconfig：wpa 的 .config 是被 Makefile
  # include 的，`CONFIG_X=n` 同样算"已定义"（会被当成开启），sed 很容易踩这个坑
  # （CONFIG_READLINE=n 就把 readline 依赖拉进来了）。这里只写确定要的。
  cat > .config <<'WCONF'
CONFIG_BACKEND=file
CONFIG_CTRL_IFACE=y
CONFIG_DRIVER_WEXT=y
CONFIG_ELOOP_POLL=y
CONFIG_IEEE80211N=y
CONFIG_INTERNAL_LIBTOMMATH=y
CONFIG_INTERNAL_LIBTOMMATH_FAST=y
CONFIG_TLS=internal
CONFIG_WPS=y
WCONF
  # 注意：不能覆盖 CFLAGS（Makefile 里的 -DCONFIG_* 都在 CFLAGS 追加链上，
  # 命令行覆盖会把它们全冲掉，症状是 dpp.c/bignum.c 一堆 "undefined type"）。
  # 正确做法是走 EXTRA_CFLAGS。
  make -j"$JOBS" CC=i486-linux-musl-gcc \
    EXTRA_CFLAGS="$CFLAGS_COMMON -I$UAPI" wpa_supplicant >/dev/null 2>&1 || {
      echo "wl: wpa_supplicant 构建失败（见上）" >&2; exit 1; }
  cd "$SRCROOT"
fi

# ---- 安装到 rootfs ----
echo "wl: 安装到 $DEST"
mkdir -p "$DEST/usr/sbin" "$DEST/usr/bin" "$DEST/etc/wpa_supplicant" "$DEST/var/run/wpa_supplicant"
for t in iwconfig iwlist iwgetid iwspy iwevent; do
  src=$SRCROOT/wireless_tools.30/$t
  [ -x "$src" ] || continue
  # iwconfig/iwlist 是老习惯在 /sbin，iwspy 等放 /usr/sbin
  case $t in
    iwconfig|iwlist) install -m 0755 "$src" "$DEST/usr/sbin/$t" ;;
    *)               install -m 0755 "$src" "$DEST/usr/sbin/$t" ;;
  esac
done
install -m 0755 "$SRCROOT/wpa_supplicant-2.10/wpa_supplicant/wpa_supplicant" \
  "$DEST/usr/sbin/wpa_supplicant"

if [ ! -f "$DEST/etc/wpa_supplicant/wpa_supplicant.conf" ]; then
  cat > "$DEST/etc/wpa_supplicant/wpa_supplicant.conf" <<'CONF'
# 最小配置：把 SSID / 口令改掉，然后
#   wpa_supplicant -B -i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf
#   udhcpc -i wlan0
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="YOUR_SSID"
	psk="YOUR_PASSPHRASE"
}
CONF
  chmod 0600 "$DEST/etc/wpa_supplicant/wpa_supplicant.conf"
fi

echo "wl: 完成（$(du -sh "$DEST/usr/sbin/wpa_supplicant" | cut -f1) wpa_supplicant）"
