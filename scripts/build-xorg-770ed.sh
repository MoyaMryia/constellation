#!/bin/sh
# 为 ThinkPad 770ED（Pentium II，无 SSE）自编 X 服务器。
#
# 为什么必须自编：Alpine 的 x86 归档基线是 Pentium III（SSE）。实测证据：
#   libpciaccess 的 pci_slot_match_iterator_create 用 `movups` 拷贝结构体，
#   PII 上执行到就 SIGILL；libgcc_s / libcrypto / libWUtil 同理。
# 修法是把 X 服务器与它启动路径上的库都用本工程的 musl i486 工具链重编，
# 并且**动态链接 musl**——静态 libc 的 dlopen 是空实现，加载不了驱动模块
# （症状：`Failed to load fbdev_drv.so: Dynamic loading not supported`）。
#
# 用法：scripts/build-xorg-770ed.sh [rootfs-dir]
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}}" && pwd)
STAGE=${XORG_STAGE:-$ROOT/build/xdeps-770ed}
SRCROOT=${XORG_SRC:-$ROOT/toolchain/src/xorg}
CC_WRAP=$ROOT/toolchain/musl-i486/bin/i486-linux-musl-gcc
MUSL_PREFIX=$ROOT/toolchain/musl-i486
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
ALPINE_VER=${ALPINE_VER:-3.20}

# xorg-server 21.1.14 + 两个驱动，钉哈希
XS_VER=21.1.14
XS_SHA=8f2102cebdc4747d1656c1099ef610f5063c7422c24a177e300de569b354ee35
FBDEV_VER=0.5.0
FBDEV_SHA=a31f62db237a5c25bb087713a22a867a9b7680833ce3b644ecd712887b7b1d62
KBD_SHA=f7c900f21752683402992b288d5a2826de7a6c0c0abac2aadd7e8a409e170388
MOUSE_SHA=4fde8ae9b44352e2a208584c36528ee3ed13cf5fe4417208a9785daccefd9968
XKBCOMP_SHA=0a288114e5f44e31987042c79aecff1ffad53a8154b8ec971c24a69a80f81f77

mkdir -p "$SRCROOT" "$STAGE"
[ -x "$CC_WRAP" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }
[ -f "$MUSL_PREFIX/lib/libc.so" ] || {
  echo "工具链是纯静态 musl：Xorg 需要动态 libc 才能 dlopen 驱动模块。" >&2
  echo "用 FORCE_TOOLCHAIN=1 scripts/build-core-770ed.sh 重建（已默认 --enable-shared）" >&2
  exit 1
}

fetch_verify () {
  url=$1; sha=$2
  file=$SRCROOT/${url##*/}
  if [ ! -f "$file" ] || ! echo "$sha  $file" | sha256sum -c - >/dev/null 2>&1; then
    echo "xorg: 下载 ${url##*/}"
    curl --fail --location --proto '=https' --silent --show-error -o "$file.tmp" "$url"
    echo "$sha  $file.tmp" | sha256sum -c -
    mv "$file.tmp" "$file"
  fi
}

# ---------- 1) 编译期依赖（Alpine -dev 只用于头文件与 .pc） ----------
if [ ! -f "$STAGE/usr/include/xorg/xf86Module.h" ]; then
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" install --root "$STAGE" \
    xorg-server-dev xorgproto xtrans libx11-dev libxext-dev libxau-dev libxdmcp-dev \
    libxfont2-dev libfontenc-dev libxkbfile-dev libpciaccess-dev libxcvt-dev \
    libxshmfence-dev pixman-dev libmd-dev zlib-dev libpng-dev freetype-dev \
    libxfixes-dev libxrender-dev libxtst-dev libevdev-dev mtdev-dev \
    font-util util-macros pkgconf >/dev/null
  # udev 头文件（eudev-dev 会带 eudev 运行时，故用 --allow-excluded）
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" install \
    --root "$STAGE" --allow-excluded eudev-dev >/dev/null
  # eudev-dev 会拖进 libsystemd（Alpine 依赖），Xorg 会因此去包含 sd-daemon.h；
  # 我们不需要 systemd 集成，直接把它从 staging 摘掉。
  rm -f "$STAGE"/usr/lib/libsystemd* "$STAGE"/usr/lib/pkgconfig/libsystemd*.pc
  # fontutil.pc 是纯数据（Alpine 的 font-util 没带 .pc）
  cat > "$STAGE/usr/lib/pkgconfig/fontutil.pc" <<'EOF'
prefix=/usr
fontrootdir=${prefix}/share/fonts
Name: FontUtil
Description: Font utilities (Constellation stub)
Version: 1.3.1
EOF
fi

export PKG_CONFIG_LIBDIR=$STAGE/usr/lib/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$STAGE
unset PKG_CONFIG_PATH

# ---------- 2) 交叉文件 ----------
cat > "$STAGE/cross.txt" <<EOF
[binaries]
c = '$CC_WRAP'
cpp = '$CC_WRAP'
ar = 'ar'
strip = 'strip'
pkgconfig = '/usr/bin/pkg-config'
[properties]
needs_exe_wrapper = true
sys_root = '$STAGE'
[built-in options]
c_args = ['-Os', '-march=i486', '-fno-stack-protector', '-I$STAGE/usr/include', '-Wno-error=array-bounds']
c_link_args = ['-L$STAGE/usr/lib', '-L$STAGE/lib', '-Wl,-rpath-link,$STAGE/usr/lib', '-Wl,-rpath-link,$STAGE/lib']
[host_machine]
system = 'linux'
cpu_family = 'x86'
cpu = 'i486'
endian = 'little'
EOF

# ---------- 3) xorg-server ----------
fetch_verify "https://www.x.org/releases/individual/xserver/xorg-server-$XS_VER.tar.xz" "$XS_SHA"
XS_DIR=$SRCROOT/xorg-server-$XS_VER
[ -d "$XS_DIR" ] || tar -C "$SRCROOT" -xf "$SRCROOT/xorg-server-$XS_VER.tar.xz"
cd "$XS_DIR"
rm -rf build
env -u PKG_CONFIG_PATH meson setup build --prefix=/usr --cross-file "$STAGE/cross.txt" \
  -Dglamor=false -Dglx=false -Ddri1=false -Ddri2=false -Ddri3=false -Ddrm=false \
  -Dudev=false -Dudev_kms=false -Dsystemd_logind=false -Dlibunwind=false \
  -Dint10=x86emu -Dsha1=libmd -Dsecure-rpc=false \
  -Dxvfb=false -Dxnest=false -Dxephyr=false -Dxwin=false -Dxquartz=false \
  -Dsuid_wrapper=false -Dxcsecurity=false -Ddtrace=false -Ddocs=false \
  -Dlinux_acpi=false -Dlinux_apm=false -Dhal=false \
  -Dxkb_bin_dir=/usr/bin -Dxkb_dir=/usr/share/X11/xkb -Dxkb_output_dir=/var/lib/xkb \
  >/dev/null
ninja -C build >/dev/null

if objdump -d build/hw/xfree86/Xorg | grep -qE 'movups|movaps|movdqa'; then
  echo "xorg: 生成的服务器含 SSE 指令" >&2; exit 1
fi

rm -rf /tmp/xorg-install-770ed
DESTDIR=/tmp/xorg-install-770ed ninja -C build install >/dev/null
cp -a /tmp/xorg-install-770ed/usr/bin/Xorg "$DEST/usr/bin/Xorg"
mkdir -p "$DEST/usr/lib/xorg/modules"
cp -a /tmp/xorg-install-770ed/usr/lib/xorg/modules/. "$DEST/usr/lib/xorg/modules/"
echo "xorg: Xorg 安装完成（$(stat -c%s "$DEST/usr/bin/Xorg") 字节）"

# ---------- 4) 驱动：fbdev（真机 tridentfb 帧缓冲）+ evdev（输入） ----------
build_auto () {
  name=$1; url=$2; sha=$3
  fetch_verify "$url" "$sha"
  dir=$SRCROOT/$name
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/${url##*/}"
  ( cd "$dir"
    export PATH=$MUSL_PREFIX/bin:$PATH
    env -u PKG_CONFIG_PATH ./configure --host=i486-linux-musl \
      --build="$(uname -m)-linux-gnu" --prefix=/usr CC=i486-linux-musl-gcc \
      CFLAGS="-Os -march=i486 -fno-stack-protector" \
      CPPFLAGS="-I$STAGE/usr/include" \
      LDFLAGS="-L$STAGE/usr/lib -L$STAGE/lib -Wl,-rpath-link,$STAGE/usr/lib -Wl,-rpath-link,$STAGE/lib" \
      >/dev/null
    make -j"$JOBS" >/dev/null
    rm -rf /tmp/drv-install-770ed
    make install DESTDIR=/tmp/drv-install-770ed >/dev/null
  )
  # 驱动的产物在 modules/ 下；纯程序（xkbcomp）在 bin/ 下
  if [ -d /tmp/drv-install-770ed/usr/lib/xorg/modules ]; then
    mkdir -p "$DEST/usr/lib/xorg/modules"
    cp -a /tmp/drv-install-770ed/usr/lib/xorg/modules/. "$DEST/usr/lib/xorg/modules/"
    echo "xorg: $name 驱动安装完成"
  fi
  if [ -d /tmp/drv-install-770ed/usr/bin ]; then
    cp -a /tmp/drv-install-770ed/usr/bin/. "$DEST/usr/bin/"
    echo "xorg: $name 程序安装完成"
  fi
}

build_auto "xf86-video-fbdev-$FBDEV_VER" \
  "https://www.x.org/releases/individual/driver/xf86-video-fbdev-$FBDEV_VER.tar.gz" "$FBDEV_SHA"
# 输入：kbd + mouse，不用 evdev —— evdev 硬依赖 libudev，而 eudev 也是
# Pentium III(SSE) 基线（实测驱动初始化时 SIGILL）。
build_auto "xf86-input-keyboard-1.9.0" \
  "https://www.x.org/releases/individual/driver/xf86-input-keyboard-1.9.0.tar.bz2" "$KBD_SHA"
build_auto "xf86-input-mouse-1.9.5" \
  "https://www.x.org/releases/individual/driver/xf86-input-mouse-1.9.5.tar.xz" "$MOUSE_SHA"

# xkbcomp：服务器编译键表要调它（Alpine 版在 libX11 里 SIGILL）
build_auto "xkbcomp-1.4.7" \
  "https://www.x.org/releases/individual/app/xkbcomp-1.4.7.tar.xz" "$XKBCOMP_SHA"

# ---------- 5) 动态 musl（我们的 Xorg 及其模块要用它） ----------
mkdir -p "$DEST/lib"
cp "$MUSL_PREFIX/lib/libc.so" "$DEST/lib/libc.so"
cp "$MUSL_PREFIX/lib/libc.so" "$DEST/lib/ld-musl-i486.so.1"
echo "xorg: 已装 /lib/libc.so 与 /lib/ld-musl-i486.so.1（我们的 musl 1.2.5）"

# ---------- 6) 依赖自检 ----------
missing=
for bin in "$DEST/usr/bin/Xorg" "$DEST/usr/lib/xorg/modules/drivers/fbdev_drv.so" \
           "$DEST/usr/lib/xorg/modules/input/evdev_drv.so"; do
  for need in $(readelf -d "$bin" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
    if [ ! -e "$DEST/usr/lib/$need" ] && [ ! -e "$DEST/lib/$need" ]; then
      missing="$missing $need(${bin##*/})"
    fi
  done
done
if [ -n "$missing" ]; then
  echo "xorg: rootfs 缺库：$missing" >&2
  exit 1
fi
echo "xorg: 依赖自检通过"
