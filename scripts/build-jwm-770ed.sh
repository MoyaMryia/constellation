#!/bin/sh
# 用本工程的 musl i486 工具链编译 JWM，装进 770ED 的 rootfs。
#
# 为什么不用 Alpine 的 IceWM/JWM/FVWM：Alpine 的 **x86** 包基线是 Pentium III
# （SSE）。实测在 `-cpu pentium2` 上，icewm/jwm/fvwm/openbox/windowmaker 全部
# 在 libgcc_s.so.1 / libWUtil.so 里 `trap invalid opcode`，而 twm/dwm/bspwm/
# Xorg/xterm 不受影响。770ED 是 Pentium II 266（无 SSE），所以桌面只能
# **自己编**：JWM 是纯 C、体积小、自带任务栏/菜单/时钟，最接近 IceWM 的用法。
#
# 头文件来自 Alpine x86 的 -dev 包（只取头与 .pc，编译产物仍是我们自己的
# musl i486 二进制，二进制里 SSE 指令数 = 0）。
#
# 用法：scripts/build-jwm-770ed.sh [rootfs-dir]
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# 必须以绝对路径处理：脚本中段会 cd 到源码目录，相对路径会写错地方
DEST=$(CDPATH= cd -- "${1:-${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}}" && pwd)
VERSION=2.4.6
SHA=b5871ec28317594b3fa22b83ed5524cc911d498c455eaab3ae68def195dd802d
URL=https://github.com/joewing/jwm/releases/download/v$VERSION/jwm-$VERSION.tar.xz
SRC=${JWM_SRC:-$ROOT/toolchain/src/jwm-$VERSION}
STAGE=${JWM_DEPS:-$ROOT/build/xdeps-770ed}
CC_WRAP=$ROOT/toolchain/musl-i486/bin/i486-linux-musl-gcc
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}

[ -x "$CC_WRAP" ] || { echo "缺少 musl i486 工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }
[ -d "$DEST" ] || { echo "缺少 rootfs：先跑 scripts/build-rootfs-770ed.sh" >&2; exit 1; }

# ---------- 1) 源码（钉版本 + 哈希） ----------
if [ ! -d "$SRC" ]; then
  mkdir -p "$ROOT/toolchain/src"
  tarball=$ROOT/toolchain/src/jwm-$VERSION.tar.xz
  if [ ! -f "$tarball" ]; then
    curl --fail --location --proto '=https' --silent --show-error -o "$tarball.tmp" "$URL"
    mv "$tarball.tmp" "$tarball"
  fi
  echo "$SHA  $tarball" | sha256sum -c -
  tar -C "$ROOT/toolchain/src" -xJf "$tarball"
fi

# ---------- 2) 头文件与 .pc（Alpine x86 -dev 包，只用于编译） ----------
if [ ! -f "$STAGE/usr/include/X11/Xlib.h" ]; then
  ALPINE_VER=${ALPINE_VER:-3.20} python3 "$ROOT/scripts/alpine-x86-770ed.py" install \
    --root "$STAGE" \
    libx11-dev libxext-dev libxmu-dev libxpm-dev libxft-dev libxrender-dev \
    libxinerama-dev libpng-dev libjpeg-turbo-dev freetype-dev fontconfig-dev \
    libxcb-dev xorgproto libxdmcp-dev libxau-dev >/dev/null
fi

# ---------- 3) 编译 ----------
export PATH=$ROOT/toolchain/musl-i486/bin:$PATH
export PKG_CONFIG_PATH=$STAGE/usr/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$STAGE
cd "$SRC"
# 工具链改过（例如 musl 从静态改成共享）时必须重跑 configure，
# 否则会链接到上一轮的产物并报 "final link failed: bad value"
make distclean >/dev/null 2>&1 || true
# 关键：--disable-pango —— Pango 走 glib，而 glib/gtk 系在 PII 上同样会踩
# Alpine 的 SSE 代码（也是我们不用 icewm 的原因）。JWM 自己的绘制够用。
./configure --host=i486-linux-musl --build="$(uname -m)-linux-gnu" \
  --prefix=/usr --disable-debug --disable-nls --enable-xft --disable-pango --disable-xinerama \
  --x-includes="$STAGE/usr/include" --x-libraries="$STAGE/usr/lib" \
  CC=i486-linux-musl-gcc \
  CPPFLAGS="-I$STAGE/usr/include" \
  CFLAGS="-Os -march=i486 -pipe -fno-stack-protector" \
  LDFLAGS="-L$STAGE/usr/lib -Wl,-rpath,/usr/lib -Wl,-rpath-link,$STAGE/usr/lib" \
  >/dev/null
make -j"$JOBS" >/dev/null

# 防线：编出来的二进制里不应有任何 SSE 指令（否则在 PII 上会 SIGILL）
if objdump -d src/jwm | grep -qE 'movaps|movdqa|pxor'; then
  echo "jwm: 生成的二进制含 SSE 指令，PII 上会非法指令" >&2
  exit 1
fi

# 依赖自检：JWM 动态链接的每个 .so 都必须在目标 rootfs 里存在，
# 否则要到真机上才发现 "Error loading shared library libjpeg.so.8"。
missing=
for need in $(readelf -d src/jwm | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
  # libc.so 是本工程 musl 的 SONAME（运行时由 /lib/ld-musl-i486.so.1 提供），
  # 不在这份"缺失库"检查里——它由 build-xorg-770ed.sh 统一安装。
  case "$need" in libc.so) continue ;; esac
  [ -e "$DEST/usr/lib/$need" ] || [ -e "$DEST/lib/$need" ] || missing="$missing $need"
done
if [ -n "$missing" ]; then
  echo "jwm: rootfs 缺少运行库:$missing" >&2
  echo "jwm: 把这些包加进 scripts/build-rootfs-770ed.sh 的 Alpine 列表" >&2
  exit 1
fi

# ---------- 4) 安装 ----------
mkdir -p "$DEST/usr/bin" "$DEST/etc/jwm" "$DEST/usr/share/jwm" "$DEST/root"
cp src/jwm "$DEST/usr/bin/jwm"
chmod 0755 "$DEST/usr/bin/jwm"
cp "$ROOT/rootfs-770ed/etc/jwm/jwmrc" "$DEST/etc/jwm/jwmrc"
cp "$ROOT/rootfs-770ed/etc/jwm/jwmrc" "$DEST/etc/system.jwmrc"
cp "$ROOT/rootfs-770ed/etc/jwm/jwmrc" "$DEST/root/.jwmrc"
# JWM 编译期 sysconfdir=/usr/etc（prefix=/usr），不带 -c 时它会去这里找
mkdir -p "$DEST/usr/etc"
cp "$ROOT/rootfs-770ed/etc/jwm/jwmrc" "$DEST/usr/etc/system.jwmrc"
chmod 0644 "$DEST/etc/jwm/jwmrc" "$DEST/etc/system.jwmrc" "$DEST/root/.jwmrc" \
  "$DEST/usr/etc/system.jwmrc"

echo "jwm: $DEST/usr/bin/jwm ($(stat -c%s "$DEST/usr/bin/jwm") 字节, SSE 指令 0)"
