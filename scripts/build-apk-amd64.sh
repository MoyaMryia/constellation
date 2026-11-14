#!/bin/sh
# Build apk-tools 3.0.7 as a static x86_64 musl binary.
#
# 设计取舍：
#   - crypto_backend = mbedtls（apk 只提供 openssl/mbedtls 两个选项，无 none）
#   2) url_backend    = libfetch：apk 自带的抓取层。原打算用 wget 绕开 TLS，
#      但实测 BusyBox wget 在被 apk 调用时段错误（wget[90]: segfault at 0），
#      故改用内置 libfetch；http 仓库不需要 TLS，mbedtls 已提供签名校验。
#   - zstd / lua / python / docs / tests 全部 disabled：本档不需要，少依赖。
#
# 源码：build/apk-src 固定在 commit 522171e（apk-tools-3.0.7），本地两处
# mbedTLS 2.x 兼容改动已固化为 third_party/patches/ 下的补丁，本脚本每次
# 先 reset 再应用，保证可复现。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TOOLCHAIN=$ROOT/toolchain/musl-amd64/bin
CC_WRAP=$TOOLCHAIN/x86_64-linux-musl-gcc
AR_WRAP=$TOOLCHAIN/x86_64-linux-musl-ar
STRIP_WRAP=$TOOLCHAIN/x86_64-linux-musl-strip
SRC=$ROOT/build/apk-src
BUILD=$ROOT/build/apk-amd64
STAGE=${APK_STAGE:-$ROOT/build/apk-amd64}
PREFIX=/usr
CROSSDEPS=${CROSSDEPS_PREFIX:-$ROOT/build/crossdeps-amd64}
HEADERS=${KERNEL_HEADERS:-$ROOT/build/hdrs-amd64}
MESON_DIR=${MESON_DIR:-$ROOT/build/pip-meson-amd64}
PATCH=$ROOT/third_party/patches/apk-tools-3.0.7-mbedtls2.patch
APK_COMMIT=522171e
CROSS_FILE=$ROOT/build/meson-cross-amd64.txt
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}

[ -x "$CC_WRAP" ] || { echo "missing cross compiler: $CC_WRAP" >&2; exit 1; }
[ -f "$HEADERS/include/linux/magic.h" ] || {
  echo "missing kernel headers at $HEADERS（apk 的 database.c include <linux/magic.h>）" >&2
  echo "先在 kernel 树里跑：make ARCH=x86_64 INSTALL_HDR_PATH=$HEADERS headers_install" >&2
  exit 1
}
[ -d "$SRC/.git" ] || { echo "missing apk source repo: $SRC" >&2; exit 1; }
[ -f "$PATCH" ] || { echo "missing patch: $PATCH" >&2; exit 1; }
command -v pkg-config >/dev/null || { echo "missing host pkg-config" >&2; exit 1; }

# 固定在钉定的上游 commit，再应用本地补丁
git -C "$SRC" checkout --quiet "$APK_COMMIT"
git -C "$SRC" checkout --quiet -- .
git -C "$SRC" apply "$PATCH"

cat > "$CROSS_FILE" <<EOF
[binaries]
c = '$CC_WRAP'
ar = '$AR_WRAP'
strip = '$STRIP_WRAP'
pkg-config = 'pkg-config'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
c_args = ['-I$HEADERS/include']
c_link_args = ['-static']
default_library = 'static'
EOF

rm -rf "$BUILD"
export PYTHONPATH=$MESON_DIR
export PKG_CONFIG_PATH=$CROSSDEPS/lib/pkgconfig
export PKG_CONFIG_LIBDIR=$CROSSDEPS/lib/pkgconfig

python3 -m mesonbuild.mesonmain setup "$BUILD" "$SRC" \
  --cross-file "$CROSS_FILE" \
  --prefix=/usr \
  -Dcrypto_backend=mbedtls \
  -Durl_backend=wget \
  -Darch=x86_64 \
  -Ddocs=disabled \
  -Dhelp=disabled \
  -Dlua=disabled \
  -Dpython=disabled \
  -Dtests=disabled \
  -Dzstd=disabled

ninja -C "$BUILD" -j"$JOBS"

DESTDIR=$STAGE python3 -m mesonbuild.mesonmain install -C "$BUILD"

"$STRIP_WRAP" "$STAGE$PREFIX/bin/apk"
echo "apk-tools (x86_64, static) installed under $STAGE$PREFIX"
file "$STAGE$PREFIX/bin/apk"
ls -l "$STAGE$PREFIX/bin/apk"
