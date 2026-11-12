#!/bin/sh
# 用本工程的 musl i486 工具链编 X 栈里"在 PII 上会 SIGILL"的那几个库。
#
# 背景：Alpine 的 **x86** 归档基线是 Pentium III（SSE）。实测硬证据：
#   libpciaccess.so 的 pci_slot_match_iterator_create 里用 `movups` 拷贝结构体
#   （偏移 0x3d0f），770ED 的 Pentium II 没有 SSE → 启动 Xorg 时
#   "Caught signal 4 (Illegal instruction)"。
# 因此凡是被 Xorg 启动路径真正调用到的库，都必须自己用 i486 编一份。
#
# 输出：直接覆盖目标 rootfs 里的同名 .so（ABI 同版本，客户端不受影响）。
#
# 用法：scripts/build-xlibs-770ed.sh [rootfs-dir]
#       OUTSIDE=1  写到 $STAGE/usr/lib（不落 rootfs，仅供后续链接）
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DEST=$(CDPATH= cd -- "${1:-${ROOTFS_DEST:-$ROOT/build/rootfs-770ed}}" && pwd)
STAGE=${XLIB_STAGE:-$ROOT/build/xlibs-770ed}
SRCROOT=${XLIB_SRC:-$ROOT/toolchain/src/xlibs}
CC_WRAP=$ROOT/toolchain/musl-i486/bin/i486-linux-musl-gcc
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}
ALPINE_VER=${ALPINE_VER:-3.20}

mkdir -p "$SRCROOT" "$STAGE"
[ -x "$CC_WRAP" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }

# TODO(pin): 这里沿用了最早的写法——只下载不钉哈希。下一步应当像
# fetch-sources.sh 那样把每个 tarball 的 sha256 写死（版本已经固定，
# 补哈希是机械工作）。
fetch () {
  url=$1
  file=$SRCROOT/${url##*/}
  if [ ! -f "$file" ]; then
    echo "xl: 下载 ${url##*/}"
    curl --fail --location --proto '=https' --silent --show-error -o "$file.tmp" "$url"
    mv "$file.tmp" "$file"
  fi
}

# 头文件/依赖的 .pc 只用于编译，来自 Alpine 的 -dev 包（不动目标 rootfs）
if [ ! -f "$STAGE/usr/include/X11/Xlib.h" ]; then
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" install --root "$STAGE" \
    libx11-dev libxext-dev libxfixes-dev libxrender-dev libxau-dev libxdmcp-dev \
    libfontenc-dev libxfont2-dev libpciaccess-dev libxcvt-dev libxshmfence-dev \
    libmd-dev libpng-dev freetype-dev zlib-dev libxcb-dev xorgproto xtrans \
    pkgconf util-macros font-util >/dev/null
fi

PC_PATH=$STAGE/usr/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$PC_PATH
export PKG_CONFIG_SYSROOT_DIR=$STAGE
unset PKG_CONFIG_PATH

cat > "$STAGE/cross.txt" <<EOF
[binaries]
c = '$CC_WRAP'
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

build_meson () {
  name=$1; url=$2; shift 2
  fetch "$url"
  dir=$SRCROOT/${url##*/}; dir=${dir%.tar.xz}; dir=${dir%.tar.gz}
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/${url##*/}"
  ( cd "$dir" && rm -rf build && \
    env -u PKG_CONFIG_PATH meson setup build --prefix=/usr --cross-file "$STAGE/cross.txt" "$@" >/dev/null && \
    ninja -C build >/dev/null && \
    DESTDIR="$STAGE" ninja -C build install >/dev/null )
  echo "xl: $name 完成"
}

build_auto () {
  name=$1; url=$2; shift 2
  fetch "$url"
  dir=$SRCROOT/${url##*/}; dir=${dir%.tar.xz}; dir=${dir%.tar.gz}; dir=${dir%.tar.bz2}
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/${url##*/}"
  ( cd "$dir" && export PATH=$ROOT/toolchain/musl-i486/bin:$PATH && \
    [ -x configure ] || ./autogen.sh >/dev/null 2>&1 || true; \
    env -u PKG_CONFIG_PATH ./configure --host=i486-linux-musl --build="$(uname -m)-linux-gnu" \
      --prefix=/usr CC=i486-linux-musl-gcc \
      CFLAGS="-Os -march=i486 -fno-stack-protector" CPPFLAGS="-I$STAGE/usr/include" \
      LDFLAGS="-L$STAGE/usr/lib -L$STAGE/lib -Wl,-rpath-link,$STAGE/usr/lib -Wl,-rpath-link,$STAGE/lib" >/dev/null && \
    make -j"$JOBS" >/dev/null && make install DESTDIR="$STAGE" >/dev/null )
  echo "xl: $name 完成"
}

# ---- 逐个编（顺序无关，但先编底层库更省事） ----
build_meson pixman        https://www.x.org/releases/individual/lib/pixman-0.43.2.tar.gz \
             -Dsse2=disabled -Dssse3=disabled -Dmmx=disabled -Dtests=disabled -Ddemos=disabled
# zlib：Alpine 的 libz.so 里带 SSE（实测 Xorg 就是死在 libz 的
# inflate/CRC 快速路径上），必须换成 i486 版本。zlib 的 configure 支持
# --archs= 直接指定目标，不给它机会开 -msse2。
build_zlib () {
  fetch https://zlib.net/fossils/zlib-1.3.2.tar.gz
  dir=$SRCROOT/zlib-1.3.2
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/zlib-1.3.2.tar.gz"
  ( cd "$dir" && export PATH=$ROOT/toolchain/musl-i486/bin:$PATH && \
    env -u PKG_CONFIG_PATH CC=i486-linux-musl-gcc \
      ./configure --prefix=/usr --archs="-march=i486 -fno-stack-protector" >/dev/null && \
    make -j"$JOBS" >/dev/null && make install DESTDIR="$STAGE" >/dev/null )
  echo "xl: zlib 完成"
}
build_zlib

build_auto  libmd         https://archive.hadrons.org/software/libmd/libmd-1.1.0.tar.xz
build_auto  libXau        https://www.x.org/releases/individual/lib/libXau-1.0.11.tar.xz
build_auto  libXdmcp      https://www.x.org/releases/individual/lib/libXdmcp-1.1.5.tar.xz
build_auto  libfontenc    https://www.x.org/releases/individual/lib/libfontenc-1.1.8.tar.xz
build_meson libpciaccess  https://www.x.org/releases/individual/lib/libpciaccess-0.18.1.tar.xz
build_auto  libXfont2     https://www.x.org/releases/individual/lib/libXfont2-2.0.6.tar.xz
build_meson libxcvt       https://www.x.org/releases/individual/lib/libxcvt-0.1.2.tar.xz

# ---- 客户端侧（xkbcomp / JWM / xterm 都要）：同样必须 i486 重编 ----
# xcb-proto 的代码生成器要跑 python3，所以用宿主 python（只生成 .c/.h）
build_xcb_proto () {
  fetch https://xorg.freedesktop.org/archive/individual/proto/xcb-proto-1.17.0.tar.xz
  dir=$SRCROOT/xcb-proto-1.17.0
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/xcb-proto-1.17.0.tar.xz"
  ( cd "$dir" && env -u PKG_CONFIG_PATH ./configure --prefix=/usr >/dev/null && \
    make install DESTDIR="$STAGE" >/dev/null )
  echo "xl: xcb-proto 完成"
}
build_xcb_proto
# libxcb 的生成脚本用 xcbproto 的 python 模块
build_libxcb () {
  fetch https://xorg.freedesktop.org/archive/individual/lib/libxcb-1.17.0.tar.xz
  dir=$SRCROOT/libxcb-1.17.0
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/libxcb-1.17.0.tar.xz"
  py=$(ls -d "$STAGE"/usr/lib/python3* 2>/dev/null | head -1)
  ( cd "$dir" && export PATH=$ROOT/toolchain/musl-i486/bin:$PATH && \
    env -u PKG_CONFIG_PATH PKG_CONFIG_LIBDIR="$STAGE/usr/lib/pkgconfig:$STAGE/usr/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR="$STAGE" PYTHONPATH="$py/site-packages" \
      ./configure --host=i486-linux-musl --build="$(uname -m)-linux-gnu" --prefix=/usr \
        CC=i486-linux-musl-gcc CFLAGS="-Os -march=i486 -fno-stack-protector" \
        CPPFLAGS="-I$STAGE/usr/include" \
        LDFLAGS="-L$STAGE/usr/lib -L$STAGE/lib -Wl,-rpath-link,$STAGE/usr/lib -Wl,-rpath-link,$STAGE/lib" \
        --disable-devel-docs >/dev/null && \
    make -j"$JOBS" >/dev/null && make install DESTDIR="$STAGE" >/dev/null )
  echo "xl: libxcb 完成"
}
build_libxcb
# libX11：交叉编译时它的 malloc(0) 运行时探测跑不了，必须显式给
# --disable-malloc0returnsnull（musl 的 malloc(0) 返回唯一指针）。
build_libX11 () {
  fetch https://www.x.org/releases/individual/lib/libX11-1.8.9.tar.xz
  dir=$SRCROOT/libX11-1.8.9
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/libX11-1.8.9.tar.xz"
  ( cd "$dir" && export PATH=$ROOT/toolchain/musl-i486/bin:$PATH && \
    env -u PKG_CONFIG_PATH PKG_CONFIG_LIBDIR="$STAGE/usr/lib/pkgconfig:$STAGE/usr/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR="$STAGE" \
      ./configure --host=i486-linux-musl --build="$(uname -m)-linux-gnu" --prefix=/usr \
        CC=i486-linux-musl-gcc CFLAGS="-Os -march=i486 -fno-stack-protector" \
        CPPFLAGS="-I$STAGE/usr/include" \
        LDFLAGS="-L$STAGE/usr/lib -L$STAGE/lib -Wl,-rpath-link,$STAGE/usr/lib -Wl,-rpath-link,$STAGE/lib" \
        --disable-malloc0returnsnull >/dev/null && \
    make -j"$JOBS" >/dev/null && make install DESTDIR="$STAGE" >/dev/null )
  echo "xl: libX11 完成"
}
build_libX11
build_auto  libxkbfile    https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz
# libtool 的 .la 会记住宿主的 /usr/lib 绝对路径，先清掉再给后续包用
rm -f "$STAGE"/usr/lib/*.la

# ---- 装进 rootfs（同 soname 覆盖 Alpine 的那份） ----
if [ "${OUTSIDE:-0}" != 1 ]; then
  for f in "$STAGE"/usr/lib/*.so.*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    # 装到与原库相同的目录：Alpine 的 zlib 在 /lib，而 musl 的搜索顺序是
    # /lib:/usr/local/lib:/usr/lib——只放 /usr/lib 会被 /lib 的老版本盖掉
    # （症状：明明换成了 i486 版本，Xorg 还是死在同一偏移）。
    if [ -e "$DEST/lib/$base" ] || [ -e "$DEST/lib/${base%%.so.*}.so.${base##*.so.}" ]; then
      cp -a "$f" "$DEST/lib/$base"
    else
      cp -a "$f" "$DEST/usr/lib/$base"
    fi
  done
  # 重建 soname 软链（libfoo.so.N -> libfoo.so.N.M.K）
  for f in "$STAGE"/usr/lib/*.so.*; do
    [ -e "$f" ] || continue
    base=${f##*/}
    case $base in
      *.so )
        soname=$(readelf -d "$f" | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
        printf 'xl: soname 链接 %s -> %s\n' "$soname" "$base"
        ;;
      *.so.*.*)
        lib=${base%%.so.*}.so
        major=$(printf '%s' "$base" | sed 's/.*\.so\.\([0-9]*\).*/\1/')
        ln -sf "$base" "$DEST/usr/lib/$lib.$major"
        ln -sf "$base" "$DEST/usr/lib/$lib"
        ;;
    esac
  done
fi

echo "xl: 目标 $DEST"
echo "xl: SSE 自检（应全部为 0）："
for so in libz.so.1 libpixman-1.so.0 libpciaccess.so.0 libXau.so.6 libXdmcp.so.6 \
          libXfont2.so.2 libfontenc.so.1 libmd.so.0 libxcvt.so.0 \
          libxcb.so.1 libX11.so.6 libxkbfile.so.1; do
  f=$(ls "$DEST"/usr/lib/$so* 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  printf '  %-20s %s\n' "$so" "$(objdump -d "$f" | grep -cE 'movups|movaps|movdqa|pxor')"
done
