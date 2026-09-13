#!/bin/sh
# Build the x86_64 static cross-dependencies needed by apk-tools 3.x:
# zlib (compression) and mbedTLS 2.28 (apk 的签名校验后端)。
#
# 为什么是 mbedTLS：apk-tools 的 crypto_backend 只有 openssl / mbedtls，
# 没有 "none"。mbedTLS 是纯 C、不依赖 perl/汇编配置，静态交叉构建摩擦最小。
# 为什么配合 url_backend=wget（见 build-apk-amd64.sh）：apk 自带的 libfetch
# 需要 TLS 栈，而 BusyBox wget 已足够取 http/local 仓库——这正是 i486 线
# 卡住的地方（docs/m2-notes.md 记"libfetch 的 TLS/链接"为阻塞项）。
#
# 源码来源：Debian pool（NJU 镜像）。zlib.net 上的 zlib-1.3.1.tar.gz 已 404
# （当前版不在 /fossils/），Debian 的 dfsg 重打包是可靠替代；mbedTLS 上游
# 无稳定直链，同样取 pool 的 orig 包。
set -e

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
CC_WRAP=$ROOT/toolchain/musl-amd64/bin/x86_64-linux-musl-gcc
AR_WRAP=$ROOT/toolchain/musl-amd64/bin/x86_64-linux-musl-ar
RANLIB_WRAP=$ROOT/toolchain/musl-amd64/bin/x86_64-linux-musl-ranlib
PREFIX=${CROSSDEPS_PREFIX:-$ROOT/build/crossdeps-amd64}
SRC=$ROOT/build/crossdeps/src
JOBS=${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '%s\n' 1)}
DEBMIRROR=${DEBMIRROR:-https://mirrors.nju.edu.cn/debian}

ZLIB_VER=1.3.1
ZLIB_TARBALL=zlib-1.3.1-dfsg.orig.tar.gz
ZLIB_SHA=60dd315c07f616887caa029408308a018ace66e3d142726a97db164b3b8f69fb
ZLIB_URL=$DEBMIRROR/pool/main/z/zlib/zlib_1.3.dfsg%2Breally1.3.1.orig.tar.gz

MBEDTLS_VER=2.28.3
MBEDTLS_TARBALL=mbedtls_2.28.3.orig.tar.gz
MBEDTLS_SHA=3b4953aa55a681e084d31892d9904cc5328d6b4958ea57b90ae4b4f94ae69a8d
MBEDTLS_URL=$DEBMIRROR/pool/main/m/mbedtls/mbedtls_2.28.3.orig.tar.gz

[ -x "$CC_WRAP" ] || { echo "missing cross compiler: $CC_WRAP" >&2; exit 1; }
mkdir -p "$SRC" "$PREFIX"

fetch () {
  tarball=$1; url=$2; sha=$3
  if [ -f "$tarball" ] && ! echo "$sha  $tarball" | sha256sum -c - >/dev/null 2>&1; then
    echo "checksum mismatch, re-fetching: $tarball" >&2
    rm -f "$tarball"
  fi
  if [ ! -f "$tarball" ]; then
    tmp=$tarball.tmp.$$
    curl --fail --location --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 300 \
      --proto '=https' --silent --show-error -o "$tmp" "$url"
    mv "$tmp" "$tarball"
  fi
  echo "$sha  $tarball" | sha256sum -c -
}

fetch "$SRC/$ZLIB_TARBALL" "$ZLIB_URL" "$ZLIB_SHA"
rm -rf "$SRC/zlib-$ZLIB_VER"
tar -C "$SRC" -xf "$SRC/$ZLIB_TARBALL"
(
  cd "$SRC/zlib-$ZLIB_VER"
  CC="$CC_WRAP" AR="$AR_WRAP" RANLIB="$RANLIB_WRAP" CFLAGS="-O2 -fPIC" \
    ./configure --prefix="$PREFIX" --static
  make -j"$JOBS"
  make install
)

fetch "$SRC/$MBEDTLS_TARBALL" "$MBEDTLS_URL" "$MBEDTLS_SHA"
rm -rf "$SRC/mbedtls-$MBEDTLS_VER"
mkdir -p "$SRC/mbedtls-$MBEDTLS_VER"
# Debian 的 orig 是 git archive，根目录名不可预期，故解到自定目录
tar -C "$SRC/mbedtls-$MBEDTLS_VER" --strip-components=1 -xf "$SRC/$MBEDTLS_TARBALL"
(
  cd "$SRC/mbedtls-$MBEDTLS_VER"
  make -j"$JOBS" lib CC="$CC_WRAP" AR="$AR_WRAP" CFLAGS="-O2 -fPIC"
  make install DESTDIR="$PREFIX" PREFIX=/
)

# mbedTLS 2.x 的 Makefile 只装库和头文件，不生成 pkg-config 文件（只有 CMake
# 构建才生成），而 apk-tools 用 dependency('mbedtls') 查找。故在此补写。
# Requires.private 链条保证静态链接顺序 mbedtls → mbedx509 → mbedcrypto。
PCDIR=$PREFIX/lib/pkgconfig
mkdir -p "$PCDIR"
cat > "$PCDIR/mbedcrypto.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mbedcrypto
Description: mbedTLS crypto library
Version: $MBEDTLS_VER
Libs: -L\${libdir} -lmbedcrypto
Cflags: -I\${includedir}
EOF
cat > "$PCDIR/mbedx509.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mbedx509
Description: mbedTLS X.509 library
Version: $MBEDTLS_VER
Requires.private: mbedcrypto
Libs: -L\${libdir} -lmbedx509
Cflags: -I\${includedir}
EOF
cat > "$PCDIR/mbedtls.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: mbedtls
Description: mbedTLS TLS library
Version: $MBEDTLS_VER
Requires.private: mbedx509
Libs: -L\${libdir} -lmbedtls
Cflags: -I\${includedir}
EOF

echo "crossdeps (x86_64) installed under $PREFIX"
ls "$PREFIX/lib"
ls "$PREFIX/lib/pkgconfig"
