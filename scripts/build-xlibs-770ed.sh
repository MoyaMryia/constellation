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
# 用来区分"我们刚编出来的"和"Alpine 的 -dev 包带进来的同名库"。
# 后面的安装步骤只复制比这个标记新的文件——否则 Alpine 那份同 soname 的
# SSE 库会被一起拷进 rootfs，还可能按字母序赢下软链（libpng 就这么中过）。
MARK=$(mktemp /tmp/xlibs-mark.XXXXXX)
[ -x "$CC_WRAP" ] || { echo "缺少工具链：先跑 scripts/build-core-770ed.sh" >&2; exit 1; }

# TODO(pin): 这里沿用了最早的写法——只下载不钉哈希。下一步应当像
# fetch-sources.sh 那样把每个 tarball 的 sha256 写死（版本已经固定，
# 补哈希是机械工作）。
fetch () {
  url=$1
  file=$SRCROOT/${url##*/}
  if [ ! -f "$file" ]; then
    echo "xl: 下载 ${url##*/}"
    # x.org 的 CDN 偶发 SSL EOF；重试 + 换镜像
    ok=0
    for try in 1 2 3; do
      if curl --fail --location --proto '=https' --silent --show-error \
              --retry 3 --retry-all-errors -o "$file.tmp" "$url" 2>/dev/null; then
        ok=1; break
      fi
      sleep 2
    done
    [ "$ok" = 1 ] || { echo "xl: 下载失败 ${url##*/}" >&2; exit 1; }
    mv "$file.tmp" "$file"
  fi
}

# 头文件/依赖的 .pc 只用于编译，来自 Alpine 的 -dev 包（不动目标 rootfs）
if [ ! -f "$STAGE/usr/include/X11/Xlib.h" ]; then
  ALPINE_VER=$ALPINE_VER python3 "$ROOT/scripts/alpine-x86-770ed.py" install --root "$STAGE" \
    libx11-dev libxext-dev libxfixes-dev libxrender-dev libxau-dev libxdmcp-dev \
    libfontenc-dev libxfont2-dev libpciaccess-dev libxcvt-dev libxshmfence-dev \
    libmd-dev libpng-dev freetype-dev zlib-dev libxcb-dev xorgproto xtrans \
    fontconfig-dev expat-dev freetype-dev libpng-dev libxpm-dev libxmu-dev \
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
c_args = ['-Os', '-O2', '-march=i486', '-mno-sse', '-mno-sse2', '-mno-mmx', '-mno-3dnow', '-fno-stack-protector', '-I$STAGE/usr/include', '-Wno-error=array-bounds']
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
    env -u PKG_CONFIG_PATH xorg_cv_malloc0_returns_null=no \
      ./configure --host=i486-linux-musl --build="$(uname -m)-linux-gnu" \
      --prefix=/usr --disable-malloc0returnsnull CC=i486-linux-musl-gcc \
      CFLAGS="-Os -O2 -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector" CPPFLAGS="-I$STAGE/usr/include" \
      LDFLAGS="-L$STAGE/usr/lib -L$STAGE/lib -Wl,-rpath-link,$STAGE/usr/lib -Wl,-rpath-link,$STAGE/lib" \
      "$@" >/dev/null && \
    # make clean 是必须的：CFLAGS 变了 make 自己不会察觉（autotools 不跟踪
    # 编译选项），会复用上一轮的 .o —— 症状就是"明明加了 -mno-sse，
    # libXinerama 里还剩 4 条 movq %xmm"。
    make clean >/dev/null 2>&1 || true
    make -j"$JOBS" >/dev/null && make install DESTDIR="$STAGE" >/dev/null )
  # .la 里记的是宿主的绝对路径（/usr/lib/xxx.la），后续包用 libtool 链接时
  # 会去读它并失败（"is not a valid libtool archive"）。删掉即可，libtool
  # 会退回用 -lxxx。
  rm -f "$STAGE"/usr/lib/*.la
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
  fetch https://www.x.org/releases/individual/proto/xcb-proto-1.17.0.tar.xz
  dir=$SRCROOT/xcb-proto-1.17.0
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/xcb-proto-1.17.0.tar.xz"
  ( cd "$dir" && env -u PKG_CONFIG_PATH ./configure --prefix=/usr >/dev/null && \
    make install DESTDIR="$STAGE" >/dev/null )
  echo "xl: xcb-proto 完成"
}
build_xcb_proto
# libxcb 的生成脚本用 xcbproto 的 python 模块
build_libxcb () {
  fetch https://www.x.org/releases/individual/lib/libxcb-1.17.0.tar.xz
  dir=$SRCROOT/libxcb-1.17.0
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/libxcb-1.17.0.tar.xz"
  py=$(ls -d "$STAGE"/usr/lib/python3* 2>/dev/null | head -1)
  ( cd "$dir" && export PATH=$ROOT/toolchain/musl-i486/bin:$PATH && \
    env -u PKG_CONFIG_PATH PKG_CONFIG_LIBDIR="$STAGE/usr/lib/pkgconfig:$STAGE/usr/share/pkgconfig" \
      PKG_CONFIG_SYSROOT_DIR="$STAGE" PYTHONPATH="$py/site-packages" \
      ./configure --host=i486-linux-musl --build="$(uname -m)-linux-gnu" --prefix=/usr \
        CC=i486-linux-musl-gcc CFLAGS="-Os -O2 -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector" \
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
        CC=i486-linux-musl-gcc CFLAGS="-Os -O2 -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector" \
        CPPFLAGS="-I$STAGE/usr/include" \
        LDFLAGS="-L$STAGE/usr/lib -L$STAGE/lib -Wl,-rpath-link,$STAGE/usr/lib -Wl,-rpath-link,$STAGE/lib" \
        --disable-malloc0returnsnull >/dev/null && \
    make clean >/dev/null 2>&1 && \
    make -j"$JOBS" >/dev/null && make install DESTDIR="$STAGE" >/dev/null )
  rm -f "$STAGE"/usr/lib/*.la
  echo "xl: libX11 完成"
}
build_libX11
build_auto  libxkbfile    https://www.x.org/releases/individual/lib/libxkbfile-1.1.3.tar.xz
# ---- 文本渲染链：st/xterm 走 Xft → fontconfig → freetype/expat ----
# 实测 st 起终端时死在 Alpine 的 libexpat（SSE）。这三个也照同样办法重编。
build_auto  expat         https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz
build_meson freetype      https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz \
             -Dbrotli=disabled -Dbzip2=disabled -Dharfbuzz=disabled -Dpng=enabled -Dzlib=enabled
# fontconfig：实测 st 起终端时第二次 SIGILL 就落在它身上（Alpine 版 66 条 SSE）
build_meson fontconfig    https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz \
             -Ddoc=disabled -Dtests=disabled -Dtools=disabled

# ---- 图像库：JWM 直接链接 jpeg/png（图标、背景），Alpine 版是 SSE 基线 ----
build_jpeg () {
  fetch https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.0.4/libjpeg-turbo-3.0.4.tar.gz
  dir=$SRCROOT/libjpeg-turbo-3.0.4
  [ -d "$dir" ] || tar -C "$SRCROOT" -xf "$SRCROOT/libjpeg-turbo-3.0.4.tar.gz"
  rm -rf "$dir/build"
  # -DWITH_SIMD=OFF：SIMD 路径由 nasm 汇编生成，那条路在 i486 上没有可用实现，
  # 关掉后是纯 C（也给 PII 省下不必要的解码开销）。
  cmake -S "$dir" -B "$dir/build" -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=i486 \
    -DCMAKE_C_COMPILER=$CC_WRAP -DCMAKE_INSTALL_PREFIX=/usr \
    -DENABLE_SHARED=ON -DENABLE_STATIC=OFF -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF \
    -DWITH_JPEG8=ON \
    -DCMAKE_C_FLAGS="-Os -O2 -march=i486 -mno-sse -mno-sse2 -mno-mmx -mno-3dnow -fno-stack-protector" \
    -DCMAKE_SHARED_LINKER_FLAGS="-L$STAGE/usr/lib -L$STAGE/lib" >/dev/null
  cmake --build "$dir/build" -j"$JOBS" >/dev/null
  DESTDIR="$STAGE" cmake --install "$dir/build" >/dev/null
  echo "xl: libjpeg-turbo 完成"
}
build_jpeg
build_auto  libpng16      https://download.sourceforge.net/libpng/libpng-1.6.43.tar.xz

# ---- 客户端用到的 X 库（xterm/xrdb 走这些；同样必须 i486） ----
# 顺序：ICE/SM → Xt → Xmu → Xpm → Xext/Xrender → Xft → Xaw
build_auto  libICE        https://www.x.org/releases/individual/lib/libICE-1.1.1.tar.xz
# libSM 默认会链 libuuid（Alpine 版是 SSE 基线）。JWM 单屏桌面根本不用
# XSMP 会话管理，所以我们显式关掉 libuuid 支持：少一个依赖、少一个 SSE 源。
build_auto  libSM         https://www.x.org/releases/individual/lib/libSM-1.2.4.tar.xz --without-libuuid
build_auto  libXt         https://www.x.org/releases/individual/lib/libXt-1.3.1.tar.xz
build_auto  libXmu        https://www.x.org/releases/individual/lib/libXmu-1.2.1.tar.xz
build_auto  libXpm        https://www.x.org/releases/individual/lib/libXpm-3.5.17.tar.xz
build_auto  libXext       https://www.x.org/releases/individual/lib/libXext-1.3.6.tar.xz
build_auto  libXrender    https://www.x.org/releases/individual/lib/libXrender-0.9.11.tar.xz
build_auto  libXft        https://www.x.org/releases/individual/lib/libXft-2.3.8.tar.xz
build_auto  libXaw        https://www.x.org/releases/individual/lib/libXaw-1.0.16.tar.xz
# libtool 的 .la 会记住宿主的 /usr/lib 绝对路径，先清掉再给后续包用
rm -f "$STAGE"/usr/lib/*.la

# ---- 装进 rootfs（按 SONAME 精确替换） ----
# 关键：staging 里同时存在"我们刚编的"和"Alpine -dev 包带进来的"同名库
# （同一个 SONAME、不同文件名，例如 libpng16.so.16.43 与 .16.57）。
# 只认比 MARK 新的**实体文件**（-type f），逐个用 readelf 取 SONAME，
# 再把 rootfs 里同 SONAME 的其它实体文件删掉后建立软链。
if [ "${OUTSIDE:-0}" != 1 ]; then
  n=0
  for dir in "$STAGE/usr/lib" "$STAGE/lib"; do
    [ -d "$dir" ] || continue
    for f in $(find "$dir" -maxdepth 1 -type f -name '*.so.*' -newer "$MARK" | sort); do
      soname=$(readelf -d "$f" 2>/dev/null | sed -n 's/.*SONAME.*\[\(.*\)\]/\1/p')
      [ -n "$soname" ] || continue
      base=${f##*/}
      # 装到与原库同级的目录：/lib 里的（zlib）必须留在 /lib，因为 musl 的
      # 搜索顺序是 /lib:/usr/local/lib:/usr/lib
      if [ -n "$(find "$STAGE/lib" -maxdepth 1 -name "$base" 2>/dev/null)" ]; then
        outdir=$DEST/lib
      else
        outdir=$DEST/usr/lib
      fi
      mkdir -p "$outdir"
      cp -a "$f" "$outdir/$base"
      for old in "$outdir/$soname".* "$outdir/$soname"; do
        [ -e "$old" ] || continue
        [ "$(basename "$old")" = "$base" ] && continue
        rm -f "$old"
      done
      ln -sf "$base" "$outdir/$soname"
      n=$((n+1))
    done
  done
  echo "xl: 安装自编库 $n 个（按 SONAME 替换 Alpine 版）"
fi

echo "xl: 目标 $DEST"
echo "xl: SSE 自检（应全部为 0）："
for so in libz.so.1 libpixman-1.so.0 libpciaccess.so.0 libXau.so.6 libXdmcp.so.6 \
          libXfont2.so.2 libfontenc.so.1 libmd.so.0 libxcvt.so.0 \
          libxcb.so.1 libX11.so.6 libxkbfile.so.1 \
          libexpat.so.1 libfreetype.so.6 libfontconfig.so.1 \
          libjpeg.so.8 libpng16.so.16 \
          libICE.so.6 libSM.so.6 libXt.so.6 libXmu.so.6 libXmuu.so.1 \
          libXpm.so.4 libXext.so.6 libXrender.so.1 libXft.so.2 libXaw.so.7; do
  f=$(ls "$DEST"/usr/lib/$so* 2>/dev/null | head -1)
  [ -n "$f" ] || continue
  printf '  %-20s %s\n' "$so" "$(objdump -d "$f" | grep -cE 'movups|movaps|movdqa|pxor')"
done
